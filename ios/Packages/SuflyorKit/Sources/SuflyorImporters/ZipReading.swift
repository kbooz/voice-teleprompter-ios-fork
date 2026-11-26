import Foundation
import SuflyorDomain
import ZIPFoundation

/// Limits shared by the importers (Kotlin: `DocumentImporter` constants).
enum ImportLimits {
    /// Containers (PDF, DOCX, ODT) may be big because of pictures; the text inside is what is capped.
    static let maxMb = 40
    static let maxBytes = maxMb * 1024 * 1024
    /// Plain-text formats: several MB of text is already far beyond any script.
    static let maxTextBytes = 8 * 1024 * 1024
    /// HTML is decoded to a String first (two bytes per char), so it gets less room than binary containers.
    static let maxMarkupBytes = 24 * 1024 * 1024
    /// About 40 000 words, five hours of speech. Longer texts are not scripts and would make the app sluggish.
    static let maxChars = 300_000
}

/// Reads parts of a zip held in memory (Kotlin: `Zip`). ZIPFoundation walks the central directory, so entries that are
/// not wanted are skipped without being inflated; their declared sizes still count against the budget.
enum ZipReading {
    /// A document part we read into memory (word/document.xml, content.xml). Pictures are only skipped over.
    static let maxEntry: Int64 = 32 * 1024 * 1024
    /// All entries of one archive together may inflate to at most this much (zip bombs).
    static let maxTotal: Int64 = 256 * 1024 * 1024
    static let maxEntries = 20_000

    private struct LimitReached: Error {}

    /// Nil when the bytes are not a readable zip (callers treat that as "no such entry").
    static func open(_ data: Data) -> Archive? {
        // Explicit `pathEncoding` picks the throwing init; the overload without it is the deprecated failable one.
        try? Archive(data: data, accessMode: .read, pathEncoding: nil)
    }

    /// Reads the named entries into memory and stops as soon as all of them are found. When skipping other entries
    /// (pictures) uses up the budget, it returns what it has: the caller decides whether the part it needs is there.
    static func read(_ data: Data, names: Set<String>) throws(ImportError) -> [String: Data] {
        guard let archive = open(data) else { return [:] }
        var out: [String: Data] = [:]
        var budget = maxTotal
        var count = 0
        for entry in archive {
            if out.count >= names.count { break }
            count += 1
            if count > maxEntries { throw .zipTooManyFiles }
            let declared = Int64(clamping: entry.uncompressedSize)
            guard names.contains(entry.path), entry.type == .file else {
                budget -= declared
                if budget < 0 { break }
                continue
            }
            if declared > maxEntry { throw .zipTooLarge }
            var buffer = Data()
            var total: Int64 = 0
            do {
                // The chunks are counted as they come, so a header that lies about the size still can't blow up.
                _ = try archive.extract(entry) { chunk in
                    total += Int64(chunk.count)
                    budget -= Int64(chunk.count)
                    if total > maxEntry || budget < 0 { throw LimitReached() }
                    buffer.append(chunk)
                }
            } catch is LimitReached {
                throw .zipTooLarge
            } catch {
                throw .unsafeDocument
            }
            out[entry.path] = buffer
        }
        return out
    }

    /// Entry names (stops at the document part, like Kotlin's `Zip.entryNames`).
    static func entryNames(_ data: Data) -> [String] {
        guard let archive = open(data) else { return [] }
        var names: [String] = []
        for entry in archive {
            if names.count >= maxEntries { break }
            names.append(entry.path)
            if entry.path == "word/document.xml" || entry.path == "content.xml" { break }
        }
        return names
    }
}
