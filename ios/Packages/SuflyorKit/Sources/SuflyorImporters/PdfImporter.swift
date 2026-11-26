import Foundation
import SuflyorDomain
#if canImport(PDFKit)
import PDFKit
#endif

/// PDF text through PDFKit (Android: PdfRenderer). Scans without a text layer are reported.
enum PdfImporter {
    static func extract(_ data: Data, title: String) throws(ImportError) -> ImportedDocument {
        #if canImport(PDFKit)
        // A file that PDFKit can't parse at all is reported like any unreadable file.
        guard let pdf = PDFDocument(data: data) else { throw .cannotOpen }
        // A password-protected PDF stays locked until it is unlocked with the password; a PDF that opens with an empty
        // password (common for "copy protected" files) is not locked.
        if pdf.isLocked { throw .pdfPassword }
        var pages: [String] = []
        var chars = 0
        for i in 0..<pdf.pageCount {
            let text = pdf.page(at: i)?.string ?? ""
            chars += text.utf16.count
            // Stops early on a book-sized PDF instead of pulling all of it into memory first.
            if chars > ImportLimits.maxChars * 2 {
                throw .textTooLong(kChars: nil, maxKChars: ImportLimits.maxChars / 1000)
            }
            pages.append(text)
        }
        var paragraphs: [ScriptParagraph] = []
        for text in PdfTextLayout.paragraphs(pages: pages) {
            var pb = ParagraphBuilder()
            pb.append(text)
            if let p = pb.build() { paragraphs.append(p) }
        }
        if paragraphs.isEmpty { throw .pdfNoTextLayer }
        return ImportedDocument(title: title, format: "PDF", paragraphs: paragraphs, warnings: [.pdfParagraphsRebuilt])
        #else
        throw .pdfUnsupported
        #endif
    }
}

/// Rebuilds paragraphs from PDF lines (port of Kotlin `PdfTextLayout`): joins wrapped lines, undoes end-of-line
/// hyphenation, drops bare page numbers.
enum PdfTextLayout {
    /// `[.!?…:»"”)]$`
    private static let sentenceEnd: Set<UInt16> = [
        ch("."), ch("!"), ch("?"), 0x2026, ch(":"), 0x00BB, ch("\""), 0x201D, ch(")"),
    ]

    static func paragraphs(pages: [String]) -> [String] {
        var lines: [Units] = []
        for page in pages {
            for raw in page.normalizedNewlines.linesKeepingEmpty {
                let line = kotlinTrim(units(raw))
                // Bare page numbers: \d{1,4}
                if (1...4).contains(line.count), line.allSatisfy(isAsciiDigit) { continue }
                lines.append(line)
            }
        }
        let lengths = lines.filter { !$0.isEmpty }.map(\.count).sorted()
        let typical = lengths.isEmpty ? 0 : lengths[(lengths.count * 3) / 4]

        var out: [String] = []
        var cur: Units = []
        func flush() {
            if !isKotlinBlank(cur) { out.append(string(kotlinTrim(cur))) }
            cur.removeAll()
        }
        for line in lines {
            if line.isEmpty {
                flush()
                continue
            }
            if cur.isEmpty {
                cur.append(contentsOf: line)
            } else if cur.last == ch("-"), cur.count >= 2, isLetter(cur[cur.count - 2]), isLowercase(line[0]) {
                cur.removeLast()
                cur.append(contentsOf: line)
            } else {
                cur.append(0x20)
                cur.append(contentsOf: line)
            }
            // A short line that ends a sentence usually ends the paragraph.
            if let end = line.last, sentenceEnd.contains(end), Double(line.count) < Double(typical) * 0.7 { flush() }
        }
        flush()
        return out
    }
}
