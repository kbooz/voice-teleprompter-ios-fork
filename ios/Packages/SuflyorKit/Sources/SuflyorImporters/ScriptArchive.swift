import Foundation
import SuflyorDomain
import ZIPFoundation

/// Backup of the whole library: a zip with one Markdown file per script, readable in any editor and by Obsidian, plus a
/// small text file with each script's own speech language. Same layout as the Android app's `ScriptArchive`, so a
/// backup made on either platform restores on the other. Only .md, .markdown and .txt files inside become scripts,
/// everything else is skipped.
public enum ScriptArchive {
    public struct Entry: Hashable, Sendable {
        /// Path of the file inside the zip.
        public var fileName: String
        public var document: ImportedDocument

        public init(fileName: String, document: ImportedDocument) {
            self.fileName = fileName
            self.document = document
        }
    }

    /// What a restore found: the scripts that parse and fit, and how many script files were left out (empty, too long,
    /// too many).
    public struct Contents: Hashable, Sendable {
        public var entries: [Entry]
        public var skipped: Int
    }

    /// "code<TAB>file name" per line, for the scripts that have their own speech language.
    static let languagesFile = "suflyor-languages.txt"

    static let maxEntries = 2_000
    static let maxScripts = 500
    /// A script longer than this can't be imported anyway (maxChars, up to 4 bytes a char).
    static let maxEntryBytes = Int64(ImportLimits.maxChars) * 4
    /// Everything the archive inflates to, skipped files included (zip bombs).
    static let maxTotal: Int64 = 32 * 1024 * 1024

    // MARK: Public API

    /// The library as a zip. Scripts are written as Markdown (`markdown(of:)`), titles become file names.
    public static func export(_ documents: [ImportedDocument]) throws -> Data {
        let scripts = documents.map { RawScript(title: $0.title, text: markdown(of: $0), speechLang: $0.speechLanguage?.code) }
        return try writeRaw(scripts)
    }

    /// The scripts of a backup, in archive order. Entries that are empty or too long are left out (see
    /// `readContents` for how many).
    public static func read(_ data: Data, core: any ScriptCoreProviding) throws(ImportError) -> [Entry] {
        try readContents(data, core: core).entries
    }

    /// Like `read`, also telling how many script files could not be restored.
    public static func readContents(_ data: Data, core: any ScriptCoreProviding) throws(ImportError) -> Contents {
        let raw = try readRaw(data)
        var entries: [Entry] = []
        var skipped = raw.dropped
        for e in raw.entries {
            let title = isKotlinBlank(units(e.title)) ? L10n.text("common_untitled") : e.title
            let doc = ImportedDocument(
                title: title,
                format: "Markdown",
                paragraphs: core.parseMarkdown(e.text, title: title),
                speechLanguage: SpeechLanguage(code: e.speechLang)
            )
            guard !doc.isEmpty, let fits = try? DocumentImporter.checkSize(doc) else {
                skipped += 1
                continue
            }
            entries.append(Entry(fileName: e.path, document: fits))
        }
        return Contents(entries: entries, skipped: skipped)
    }

    /// A zip that holds text files and is not a DOCX or ODT (those are zips too). The app tries this before the normal
    /// import, as the Android app does.
    public static func isArchive(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(2))
        if head.count < 2 || head[0] != 0x50 || head[1] != 0x4B { return false }
        let names = ZipReading.entryNames(data)
        if names.contains("word/document.xml") || names.contains("content.xml") || names.contains("mimetype") {
            return false
        }
        return names.contains(where: isScriptFile)
    }

    /// Markdown text of one script (also used for "Share text"): headings as `# `, emphasis as `**`.
    public static func markdown(of document: ImportedDocument) -> String {
        var blocks: [String] = []
        for p in document.paragraphs {
            switch p.kind {
            case .heading:
                blocks.append("# " + p.text)
            case .body:
                let text = units(p.text)
                var out: Units = []
                var last = 0
                for r in p.emphasis.sorted(by: { $0.start < $1.start }) {
                    if r.start < last || r.end > text.count || r.end <= r.start { continue }
                    out.append(contentsOf: text[last..<r.start])
                    out.append(contentsOf: [ch("*"), ch("*")])
                    out.append(contentsOf: text[r.start..<r.end])
                    out.append(contentsOf: [ch("*"), ch("*")])
                    last = r.end
                }
                out.append(contentsOf: text[last...])
                blocks.append(string(out))
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Raw layer (what Kotlin's `ScriptArchive.Entry` holds), also used by the tests

    struct RawScript: Hashable {
        var title: String
        var text: String
        var speechLang: String?
    }

    struct RawEntry: Hashable {
        var path: String
        var title: String
        var text: String
        var speechLang: String?
    }

    struct RawContents: Hashable {
        var entries: [RawEntry]
        var dropped: Int
    }

    static func writeRaw(_ scripts: [RawScript]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)

        func add(_ name: String, _ content: Data) throws {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(content.count), compressionMethod: .deflate
            ) { position, size in
                let start = Data.Index(position)
                return content.subdata(in: start..<(start + size))
            }
        }

        var used = Set<String>()
        var languages = ""
        for script in scripts {
            let base = fileName(script.title)
            var name = "\(base).md"
            var n = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(base) (\(n)).md"
                n += 1
            }
            try add(name, Data(script.text.utf8))
            if let code = script.speechLang { languages += "\(code)\t\(name)\n" }
        }
        if !languages.isEmpty { try add(languagesFile, Data(languages.utf8)) }
        guard let data = archive.data else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private struct TooLong: Error {}

    static func readRaw(_ data: Data) throws(ImportError) -> RawContents {
        guard let archive = ZipReading.open(data) else { return RawContents(entries: [], dropped: 0) }
        var files: [(path: String, text: String)] = []
        var languages = ""
        var budget = maxTotal
        var count = 0
        var dropped = 0
        for entry in archive {
            count += 1
            if count > maxEntries { throw .zipTooManyFiles }
            let isLanguages = entry.path == languagesFile
            let wanted = entry.type == .file && (isLanguages || isScriptFile(entry.path))
            if wanted, !isLanguages, files.count >= maxScripts { dropped += 1 }
            let keep = wanted && (isLanguages || files.count < maxScripts)
            // Every entry counts against the budget by its declared size, skipped ones too (they are never inflated).
            let declared = Int64(clamping: entry.uncompressedSize)
            budget -= declared
            if budget < 0 { throw .zipTooLarge }
            if !keep { continue }
            if declared > maxEntryBytes {
                if !isLanguages { dropped += 1 }
                continue
            }
            var buffer = Data()
            do {
                // The chunks are counted too, so a header that lies about the size still can't blow up.
                _ = try archive.extract(entry) { chunk in
                    if Int64(buffer.count + chunk.count) > maxEntryBytes { throw TooLong() }
                    buffer.append(chunk)
                }
            } catch is TooLong {
                if !isLanguages { dropped += 1 }
                continue
            } catch {
                throw .unsafeDocument
            }
            let extra = Int64(buffer.count) - declared
            if extra > 0 {
                budget -= extra
                if budget < 0 { throw .zipTooLarge }
            }
            if isLanguages {
                languages = String(decoding: buffer, as: UTF8.self)
            } else {
                files.append((entry.path, TextDecoding.decode(buffer)))
            }
        }
        var languageOf: [String: String] = [:]
        for line in languages.normalizedNewlines.linesKeepingEmpty {
            let u = units(line)
            let tab = u.find(0x09, from: 0)
            if tab > 0 { languageOf[string(u[(tab + 1)...])] = string(u[..<tab]) }
        }
        let entries = files.map { file -> RawEntry in
            let base = file.path.split(separator: "/", omittingEmptySubsequences: false).last.map { String($0) } ?? file.path
            let stem = base.lastIndex(of: ".").map { String(base[..<$0]) } ?? base
            return RawEntry(
                path: file.path,
                title: string(kotlinTrim(units(stem))),
                text: file.text,
                speechLang: languageOf[file.path]
            )
        }
        return RawContents(entries: entries, dropped: dropped)
    }

    static func isScriptFile(_ name: String) -> Bool {
        let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map { String($0) } ?? name
        // macOS adds "__MACOSX/._name" resource forks next to every file.
        if base.hasPrefix("._") || name.hasPrefix("__MACOSX/") { return false }
        guard let dot = base.lastIndex(of: ".") else { return false }
        let ext = base[base.index(after: dot)...].lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
    }

    /// A title that is safe as a file name on every system and is not hidden; never empty.
    static func fileName(_ title: String) -> String {
        var cleaned: Units = []
        var previousSpace = false
        for c in title.utf16 {
            let unsafe = c == ch("\\") || c == ch("/") || c == ch(":") || c == ch("*") || c == ch("?") ||
                c == ch("\"") || c == ch("<") || c == ch(">") || c == ch("|") || c < 0x20 || c == 0x7F
            let x: UInt16 = unsafe ? 0x20 : c
            if x == 0x20 {
                if previousSpace { continue }
                previousSpace = true
            } else {
                previousSpace = false
            }
            cleaned.append(x)
        }
        var u = kotlinTrim(cleaned)
        while u.first == ch(".") { u.removeFirst() }
        while u.last == ch(".") { u.removeLast() }
        u = kotlinTrim(u)
        if u.count > 80 {
            u = Array(u.prefix(80))
            // Don't cut a surrogate pair in half.
            if let last = u.last, last >= 0xD800, last <= 0xDBFF { u.removeLast() }
        }
        let s = string(u)
        return s.isEmpty ? "script" : s
    }
}
