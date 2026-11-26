import Foundation
import SuflyorDomain
import SuflyorTestSupport
import Testing

@testable import SuflyorImporters

// Port of the app's ScriptArchiveTest.kt, on the raw layer (title + Markdown text, as Kotlin's `Entry`), plus the
// public API (documents) and the Android-made backup fixture.

@Suite("ScriptArchive")
struct ScriptArchiveTests {
    typealias Raw = ScriptArchive.RawScript

    @Test func roundTripKeepsTitlesTextLanguageAndOrder() throws {
        let scripts = [
            Raw(title: "Дрон для путешествий",
                text: "# Вступление\n\nСегодня **разберём**, как выбрать дрон.\n\n[пауза] И не переплатить.", speechLang: nil),
            Raw(title: "Second", text: "Plain English text.", speechLang: "en"),
        ]
        let bytes = try ScriptArchive.writeRaw(scripts)
        #expect(ScriptArchive.isArchive(bytes))
        let contents = try ScriptArchive.readRaw(bytes)
        #expect(contents.entries.map { Raw(title: $0.title, text: $0.text, speechLang: $0.speechLang) } == scripts)
        #expect(contents.dropped == 0)
    }

    @Test func sameUnsafeAndHiddenTitlesGetDistinctVisibleNames() throws {
        let bytes = try ScriptArchive.writeRaw([
            Raw(title: "a/b:c?", text: "one", speechLang: nil),
            Raw(title: "a/b:c?", text: "two", speechLang: nil),
            Raw(title: "", text: "three", speechLang: nil),
            Raw(title: "...", text: "four", speechLang: nil),
            Raw(title: ".NET notes", text: "five", speechLang: nil),
        ])
        let titles = try ScriptArchive.readRaw(bytes).entries.map(\.title)
        #expect(titles == ["a b c", "a b c (2)", "script", "script (2)", "NET notes"])
    }

    @Test func fileNames() {
        #expect(ScriptArchive.fileName("  Hello \t world  ") == "Hello world")
        #expect(ScriptArchive.fileName(String(repeating: "x", count: 200)).utf16.count == 80)
        #expect(ScriptArchive.fileName("😀") == "😀")
    }

    @Test func officeDocumentsAndForeignZipsAreNotArchives() throws {
        #expect(!ScriptArchive.isArchive(try Fixture.data("archive-office.zip")))
        #expect(!ScriptArchive.isArchive(try Fixture.data("archive-odf.zip")))
        #expect(!ScriptArchive.isArchive(try Fixture.data("archive-foreign.zip")))
        #expect(!ScriptArchive.isArchive(Data("not a zip".utf8)))
        #expect(!ScriptArchive.isArchive(try Fixture.data("basic.docx")))
    }

    @Test func onlyTextFilesAreRead() throws {
        let entries = try ScriptArchive.readRaw(try Fixture.data("archive-files.zip")).entries
        #expect(entries.map(\.title) == ["one", "two"])
        #expect(entries.map(\.text) == ["first", "second"])
        #expect(entries.map(\.path) == ["folder/one.md", "two.txt"])
    }

    @Test func tooLongScriptIsDroppedAndCounted() throws {
        let contents = try ScriptArchive.readRaw(try Fixture.data("archive-too-long.zip"))
        #expect(contents.entries.map(\.title) == ["ok"])
        #expect(contents.entries.map(\.text) == ["fine"])
        #expect(contents.dropped == 1)
    }

    @Test func zipBombIsRefusedEvenInSkippedFiles() throws {
        // 40 MB of zeros in a file that is not a script still counts against the budget.
        #expect(errorOf { try ScriptArchive.readRaw(try Fixture.data("archive-bomb.zip")) } == .zipTooLarge)
    }

    @Test func androidMadeBackupRestores() throws {
        let data = try Fixture.data("android-backup.zip")
        #expect(ScriptArchive.isArchive(data))
        let raw = try ScriptArchive.readRaw(data)
        #expect(raw.entries.map(\.title) == ["Дрон для путешествий", "Second"])
        #expect(raw.entries.map(\.speechLang) == [nil, "en"])
        #expect(raw.entries[0].text.hasPrefix("# Вступление"))

        let contents = try ScriptArchive.readContents(data, core: SimpleScriptCore())
        #expect(contents.skipped == 0)
        #expect(contents.entries.map(\.fileName) == ["Дрон для путешествий.md", "Second.md"])
        #expect(contents.entries.map(\.document.title) == ["Дрон для путешествий", "Second"])
        #expect(contents.entries.map(\.document.speechLanguage) == [nil, .en])
        #expect(contents.entries.allSatisfy { $0.document.format == "Markdown" && !$0.document.isEmpty })
    }

    @Test func exportReadsBackThroughThePublicApi() throws {
        let docs = [
            ImportedDocument(
                title: "Скрипт: тест?",
                format: "Markdown",
                paragraphs: [ScriptParagraph(text: "Plain words here", kind: .body)],
                speechLanguage: .ru
            ),
            ImportedDocument(title: "Two", format: "TXT", paragraphs: [ScriptParagraph(text: "More words", kind: .body)]),
        ]
        let bytes = try ScriptArchive.export(docs)
        #expect(ScriptArchive.isArchive(bytes))
        let entries = try ScriptArchive.read(bytes, core: SimpleScriptCore())
        #expect(entries.map(\.fileName) == ["Скрипт тест.md", "Two.md"])
        #expect(entries.map(\.document.speechLanguage) == [.ru, nil])
    }

    @Test func markdownOfDocument() {
        let doc = ImportedDocument(title: "t", format: "Markdown", paragraphs: [
            ScriptParagraph(text: "Вступление", kind: .heading),
            ScriptParagraph(text: "Сегодня разберём, как выбрать дрон.", kind: .body, emphasis: [TextRange(start: 8, end: 16)]),
            // Overlapping and out-of-range emphasis is skipped, as on Android.
            ScriptParagraph(text: "abcdef", kind: .body, emphasis: [
                TextRange(start: 1, end: 3), TextRange(start: 2, end: 4), TextRange(start: 5, end: 99),
            ]),
            // Offsets are UTF-16 units: the emoji takes two.
            ScriptParagraph(text: "😀 bold", kind: .body, emphasis: [TextRange(start: 3, end: 7)]),
        ])
        #expect(ScriptArchive.markdown(of: doc) ==
            "# Вступление\n\nСегодня **разберём**, как выбрать дрон.\n\na**bc**def\n\n😀 **bold**")
    }
}
