import Foundation
import SuflyorDomain
import Testing

@testable import SuflyorImporters

// Port of the app's ImportersTest.kt. Cases that exercise the shared Markdown parser, the phrase breaker or the
// layout (markdownKeepsHeadingsAndBold..., markdownLongSpansAndHostileLines, secondReviewRegressions (Markdown half),
// phraseBreaking, layoutOffsetsStayConsistent) belong to the Kotlin core tests, and builtInSampleInBothLanguages
// checks Android resources (tools/ios/test_convert_strings.py covers the catalog).

private let ru = "Привет, мир! Это проверка кодировки: ёжик и щука."

@Suite("Text decoding and plain text")
struct PlainTextTests {
    @Test func decodesCommonRussianEncodings() throws {
        for name in [
            "ru-utf8.txt", "ru-utf8-bom.txt", "ru-utf16le-bom.txt", "ru-utf16le.txt", "ru-utf16be.txt",
            "ru-cp1251.txt", "ru-koi8r.txt",
        ] {
            #expect(TextDecoding.decode(try Fixture.data(name)) == ru, "\(name)")
        }
    }

    @Test func plainTextParagraphs() {
        let lines = PlainTextImporter.parse("Первая строка\nВторая строка\nТретья", title: "t")
        #expect(lines.paragraphs.count == 3)
        let blocks = PlainTextImporter.parse("Абзац один,\nпродолжение.\n\nАбзац два.", title: "t")
        #expect(texts(blocks) == ["Абзац один, продолжение.", "Абзац два."])
        // CR and CRLF line breaks are line breaks too.
        #expect(texts(PlainTextImporter.parse("a\r\nb\rc", title: "t")) == ["a", "b", "c"])
    }

    @Test func emphasisOffsetsAreUtf16() {
        // An emoji is two UTF-16 units: the range after it must count both.
        var pb = ParagraphBuilder()
        pb.append("😀 ")
        pb.append("жирный", emphasized: true)
        let p = pb.build()
        #expect(p?.text == "😀 жирный")
        #expect(p?.emphasis == [TextRange(start: 3, end: 9)])
    }

    @Test func builderCollapsesWhitespaceAndDropsInvisibles() {
        var pb = ParagraphBuilder()
        pb.append("  a\u{00A0}\u{00A0}b\u{200B}c \n d  ")
        #expect(pb.build()?.text == "a bc d")
        // NFC: "e" + combining acute becomes one character.
        pb.clear()
        pb.append("cafe\u{0301}")
        #expect(pb.build()?.text == "caf\u{00E9}")
    }
}

@Suite("RTF")
struct RtfTests {
    @Test func codepageUnicodeAndBold() throws {
        let doc = try RtfImporter.parse(try Fixture.data("cp1251.rtf"), title: "t")
        let p = doc.paragraphs[0]
        #expect(p.text == "Привет мир!")
        #expect(emphasized(p) == ["мир"])
        #expect(doc.paragraphs[1].text == "Второй")
        #expect(doc.format == "RTF")
    }

    @Test func fontCharsetOverridesDocumentCodepage() throws {
        // WordPad on an English Windows: \ansicpg1252, Cyrillic text in a \fcharset204 font.
        let doc = try RtfImporter.parse(try Fixture.data("font-charset.rtf"), title: "t")
        #expect(doc.paragraphs[0].text == "Привет café")
    }

    @Test func absurdFontNumbersStillImport() throws {
        let doc = try RtfImporter.parse(try Fixture.data("absurd-fonts.rtf"), title: "t")
        #expect(texts(doc) == ["Hello"])
    }

    @Test func surrogatePairsFromUnicodeEscapes() throws {
        let doc = try RtfImporter.parse(try Fixture.data("emoji.rtf"), title: "t")
        #expect(texts(doc) == ["Hi \u{1F600}!"])
    }

    @Test func notRtf() throws {
        #expect(errorOf { try RtfImporter.parse(try Fixture.data("not-rtf.rtf"), title: "t") } == .notRtf)
    }
}

@Suite("HTML")
struct HtmlTests {
    @Test func blocksAndEntities() throws {
        let doc = HtmlImporter.parse(String(decoding: try Fixture.data("basic.html"), as: UTF8.self), title: "t")
        #expect(texts(doc) == ["Тема", "Раз «два» три", "Четыре", "пять"])
        #expect(doc.paragraphs[0].kind == .heading)
        #expect(emphasized(doc.paragraphs[1]) == ["три"])
        // The page's own <title> wins over the file name.
        #expect(doc.title == "T")
    }

    @Test func declarationsDataUrisAndOptionalHead() throws {
        let doc = HtmlImporter.parse(String(decoding: try Fixture.data("declarations.html"), as: UTF8.self), title: "t")
        #expect(doc.title == "Мой")
        #expect(texts(doc) == ["Первый абзац.", "1.", "Второй.", "без закрытия", "Третий."])
        let xhtml = HtmlImporter.parse(String(decoding: try Fixture.data("xhtml.html"), as: UTF8.self), title: "t")
        #expect(texts(xhtml) == ["Текст"])
    }

    @Test func bodyMentionedInsideClosedHead() throws {
        let doc = HtmlImporter.parse(String(decoding: try Fixture.data("body-in-head.html"), as: UTF8.self), title: "t")
        #expect(texts(doc) == ["Текст"])
    }

    @Test func scriptsAndCommentsDisappear() throws {
        let doc = HtmlImporter.parse(String(decoding: try Fixture.data("script-comment.html"), as: UTF8.self), title: "t")
        #expect(texts(doc) == ["Текст"])
    }

    @Test func entities() {
        #expect(HtmlImporter.decode("a&amp;b &#1055; &#x41; &unknown; &#xZZ; &#99999999999; &lt;") == "a&b П A &unknown; &#xZZ; &#99999999999; <")
    }

    @Test func boldSpans() {
        let doc = HtmlImporter.parse("<p>a <span style=\"FONT-WEIGHT : 700\">b</span> <span style=\"font-weight:normal\">c</span></p>", title: "t")
        #expect(emphasized(doc.paragraphs[0]) == ["b"])
    }

    @Test func hostileMarkupStaysLinear() {
        let html = "<p>" + String(repeating: "<", count: 20_000) + "a <!-- x" + String(repeating: "<script", count: 2_000) + "</p>"
        let unclosed = String(repeating: "<a ", count: 100_000)
        let elapsed = ContinuousClock().measure {
            _ = HtmlImporter.parse(html, title: "t")
            _ = HtmlImporter.parse(unclosed, title: "t")
        }
        #expect(elapsed < .seconds(3))
    }
}

@Suite("DOCX and ODT")
struct OfficeTests {
    @Test func paragraphsHeadingsBoldAndDeletions() throws {
        let data = try Fixture.data("basic.docx")
        let doc = try DocxImporter.parse(data, title: "t")
        #expect(texts(doc) == ["Заголовок", "Обычный жирный текст", "Не жирный"])
        #expect(doc.paragraphs[0].kind == .heading)
        #expect(emphasized(doc.paragraphs[1]) == ["жирный"])
        #expect(doc.paragraphs[2].emphasis.isEmpty)
        #expect(doc.warnings.isEmpty)
        let kind = DocumentImporter.detect(data: data, bytes: [UInt8](data), fileName: "x.bin", contentType: nil)
        #expect(kind == .docx)
    }

    @Test func strictNamespaceWithOtherPrefix() throws {
        let doc = try DocxImporter.parse(try Fixture.data("strict.docx"), title: "t")
        #expect(texts(doc) == ["Заголовок", "Обычный жирный текст", "Не жирный"])
        #expect(doc.paragraphs[0].kind == .heading)
    }

    @Test func odtParagraphs() throws {
        let doc = try OdtImporter.parse(try Fixture.data("basic.odt"), title: "t")
        #expect(texts(doc) == ["Тема", "Раз два"])
        #expect(doc.paragraphs[0].kind == .heading)
        #expect(doc.format == "ODT")
    }

    @Test func tablesAreWarnedAbout() throws {
        let doc = try DocxImporter.parse(try Fixture.data("tables.docx"), title: "t")
        #expect(doc.warnings == [.docxTables(count: 1)])
        #expect(texts(doc) == ["ячейка"])
    }

    @Test func docxWithDtdIsRefusedWhereverItHides() throws {
        #expect(errorOf { try DocxImporter.parse(try Fixture.data("dtd-late.docx"), title: "t") } == .unsafeDocument)
    }

    @Test func textLimitIsAnImportError() throws {
        let error = errorOf { try DocxImporter.parse(try Fixture.data("long.docx"), title: "t") }
        #expect(error == .textTooLong(kChars: nil, maxKChars: 300))
    }

    @Test func nestedParagraphsAreCapped() throws {
        let doc = try DocxImporter.parse(try Fixture.data("nested.docx"), title: "t")
        #expect(texts(doc) == ["глубоко"])
    }

    @Test func absurdlyDeepNestingDoesNotCrash() throws {
        // Android's SAX parser reads 100 000 levels; libxml2 (XMLParser) stops at its depth limit. Either is fine as
        // long as it is an answer and not a crash.
        let error = errorOf { try DocxImporter.parse(try Fixture.data("nested-deep.docx"), title: "t") }
        #expect(error == nil || error == .unsafeDocument)
    }

    @Test func zipBombIsRefused() throws {
        #expect(errorOf { try DocxImporter.parse(try Fixture.data("zip-bomb.docx"), title: "t") } == .zipTooLarge)
    }

    @Test func missingDocumentPart() throws {
        #expect(errorOf { try DocxImporter.parse(try Fixture.data("basic.odt"), title: "t") } == .notDocx)
        #expect(errorOf { try OdtImporter.parse(try Fixture.data("basic.docx"), title: "t") } == .notOdt)
    }
}

@Suite("PDF text layout")
struct PdfLayoutTests {
    @Test func linesBecomeParagraphs() {
        let page = [
            "Это длинная строка текста, которая переносится на следующую стро-",
            "ку и продолжается дальше почти до самого конца этой строки текста,",
            "а потом заканчивается коротко.",
            "12",
            "Новый абзац начинается здесь и тоже идёт на всю ширину строки.",
        ].joined(separator: "\n")
        let out = PdfTextLayout.paragraphs(pages: [page])
        #expect(out[0] == "Это длинная строка текста, которая переносится на следующую строку и продолжается дальше почти " +
            "до самого конца этой строки текста, а потом заканчивается коротко.")
        #expect(out.count == 2)
    }

    #if canImport(PDFKit)
    @Test func textPdf() throws {
        let doc = try PdfImporter.extract(try Fixture.data("text.pdf"), title: "t")
        #expect(doc.format == "PDF")
        #expect(doc.warnings == [.pdfParagraphsRebuilt])
        #expect(texts(doc).joined(separator: " ").contains("Hello Suflyor"))
    }

    @Test func scanHasNoTextLayer() throws {
        #expect(errorOf { try PdfImporter.extract(try Fixture.data("scan.pdf"), title: "t") } == .pdfNoTextLayer)
    }

    @Test func passwordProtected() throws {
        #expect(errorOf { try PdfImporter.extract(try Fixture.data("password.pdf"), title: "t") } == .pdfPassword)
    }

    @Test func brokenPdf() throws {
        #expect(errorOf { try PdfImporter.extract(try Fixture.data("not-a-pdf.pdf"), title: "t") } == .cannotOpen)
    }
    #endif
}

@Suite("DocumentImporter")
struct DocumentImporterTests {
    let importer = makeImporter()

    @Test func importErrorsAndDefaultTitle() throws {
        func importFile(_ data: Data, _ name: String) throws -> ImportedDocument {
            try importer.importFile(data: data, fileName: name, contentType: nil)
        }
        #expect(errorOf { try importFile(Data(), "a.txt") } == .emptyFile)
        #expect(errorOf { try importFile(Data(" \n\n ".utf8), "a.txt") } == .noText)
        #expect(errorOf { try importFile(try Fixture.data("control-chars.bin"), "a.bin") } == .notText)
        #expect(errorOf { try importFile(try Fixture.data("legacy.doc"), "a.doc") } == .legacyDoc)
        #expect(errorOf { try importFile(try Fixture.data("encrypted.docx"), "a.docx") } == .encryptedOffice)
        #expect(errorOf { try importFile(try Fixture.data("unknown.zip"), "a.zip") } == .unknownZip)
        #expect(errorOf { try importFile(Data(count: 41 * 1024 * 1024), "big.pdf") } == .fileTooBig(maxMb: 40))
        #expect(errorOf { try importFile(Data(repeating: 0x61, count: 9 * 1024 * 1024), "big.txt") } == .textFileTooBig)

        // The caller's default title only when the file has no name.
        #expect(try importFile(Data("Text".utf8), "").title == L10n.text("common_untitled"))
        #expect(try importFile(Data("Text".utf8), ".txt").title == L10n.text("common_untitled"))
        #expect(try importFile(Data("Text".utf8), "notes.txt").title == "notes")
        #expect(try importFile(Data("Text".utf8), "folder/notes.final.txt").title == "notes.final")
    }

    @Test func pastedTextTooLong() {
        let long = String(repeating: "слово ", count: 60_000)
        #expect(errorOf { try importer.importPastedText(long, title: "t") } == .textTooLong(kChars: 359, maxKChars: 300))
        let huge = String(repeating: "a", count: 600_001)
        #expect(errorOf { try importer.importPastedText(huge, title: "t") } == .pastedTextTooLong)
    }

    @Test func formatsAndDispatch() throws {
        let rtf = try importer.importFile(data: try Fixture.data("cp1251.rtf"), fileName: "x.rtf", contentType: nil)
        #expect(rtf.format == "RTF")
        #expect(rtf.title == "x")
        let docx = try importer.importFile(data: try Fixture.data("basic.docx"), fileName: "x.bin", contentType: nil)
        #expect(docx.format == "DOCX")
        let odt = try importer.importFile(data: try Fixture.data("basic.odt"), fileName: "x", contentType: nil)
        #expect(odt.format == "ODT")
        // HTML by extension, by content type and by content.
        let basic = try Fixture.data("basic.html")
        for (name, type) in [("a.html", nil), ("a.bin", "public.html"), ("a.txt", nil)] as [(String, String?)] {
            let html = try importer.importFile(data: basic, fileName: name, contentType: type)
            #expect(html.format == "HTML", "\(name) \(type ?? "-")")
        }
        let txt = try importer.importFile(data: try Fixture.data("ru-cp1251.txt"), fileName: "a.txt", contentType: nil)
        #expect(txt.format == "TXT")
        #expect(txt.paragraphs.first?.text == ru)
        // Markdown goes to the shared core.
        let md = try importer.importFile(data: Data("# Title\n\nBody".utf8), fileName: "a.md", contentType: nil)
        #expect(md.format == "Markdown")
        let md2 = try importer.importFile(data: Data("# Title\n\nBody".utf8), fileName: "a.txt", contentType: "net.daringfireball.markdown")
        #expect(md2.format == "Markdown")
    }

    @Test func pastedTextPicksMarkdownOrPlain() throws {
        #expect(try importer.importPastedText("# Heading\ntext", title: "t").format == "Markdown")
        #expect(try importer.importPastedText("some **bold** words", title: "t").format == "Markdown")
        #expect(try importer.importPastedText("- item", title: "t").format == "Markdown")
        #expect(try importer.importPastedText("just words 2*3*4", title: "t").format == "TXT")
        #expect(try importer.importPastedText("#hashtag", title: "t").format == "TXT")
        #expect(try importer.importPastedText("####### seven", title: "t").format == "TXT")
        #expect(try importer.importPastedText("a\r# b", title: "t").format == "Markdown")
        #expect(try importer.importPastedText("text", title: nil).title == L10n.text("import_title_clipboard"))
    }

    @Test func supportedTypes() {
        let ids = DocumentImporter.supportedContentTypes.map(\.identifier)
        #expect(ids.contains("com.adobe.pdf"))
        #expect(ids.contains("public.rtf"))
        #expect(ids.count >= 6)
        #expect(Set(ids).count == ids.count)
    }

    @Test func warningCodes() {
        for warning in [ImportWarning.pdfParagraphsRebuilt, .docxTables(count: 3), .raw("Что-то: raw:1")] {
            #expect(ImportWarning(code: warning.code) == warning)
        }
        #expect(ImportWarning(code: "from_a_newer_version") == nil)
    }
}
