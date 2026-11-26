import Foundation
import Testing
@testable import SuflyorDomain

@Suite struct ImportWarningTests {
    @Test(arguments: [
        ImportWarning.pdfParagraphsRebuilt,
        .docxTables(count: 3),
        .docxTables(count: 0),
        .raw("Tables in this DOCX come out as their cells: check the order"),
        .raw(""),
    ])
    func codeRoundTrips(warning: ImportWarning) {
        #expect(ImportWarning(code: warning.code) == warning)
    }

    @Test func usesTheSameCodesAsAndroid() {
        #expect(ImportWarning.pdfParagraphsRebuilt.code == "pdf_paragraphs")
        #expect(ImportWarning.docxTables(count: 2).code == "docx_tables:2")
        #expect(ImportWarning.raw("old").code == "raw:old")
    }

    @Test func unknownCodeIsNil() {
        #expect(ImportWarning(code: "from_a_newer_version") == nil)
        #expect(ImportWarning(code: "docx_tables:many") == nil)
        #expect(ImportWarning(code: "") == nil)
    }
}

@Suite struct ScrollModeTests {
    @Test func nextStepsThroughTheModesInAndroidOrder() {
        #expect(ScrollMode.voice.next == .auto)
        #expect(ScrollMode.auto.next == .sound)
        #expect(ScrollMode.sound.next == .voice)
    }

    @Test func allCasesAreInTheOrderTheButtonUses() {
        #expect(ScrollMode.allCases == [.voice, .auto, .sound])
    }
}

@Suite struct PrompterSettingsTests {
    private func decode(_ json: String) -> PrompterSettings {
        PrompterSettings.decodeMergingDefaults(Data(json.utf8))
    }

    @Test func missingKeysKeepTheirDefaults() {
        let settings = decode(#"{"leadWords": 3, "autoScrollWpm": 200}"#)
        #expect(settings.leadWords == 3)
        #expect(settings.autoScrollWpm == 200)
        #expect(settings.phraseMode == PrompterSettings().phraseMode)
        #expect(settings.maxWords == PrompterSettings().maxWords)
        #expect(settings.keyBindings == KeyBindings.default)
        #expect(settings.countdownSeconds == 3)
    }

    @Test func emptyObjectGivesTheDefaults() {
        #expect(decode("{}") == PrompterSettings())
    }

    @Test func unknownKeysAreIgnored() {
        let settings = decode(#"{"fontSize": 40, "addedByANewerVersion": {"a": [1, 2]}, "another": "x"}"#)
        #expect(settings.fontSize == 40)
        var expected = PrompterSettings()
        expected.fontSize = 40
        #expect(settings == expected)
    }

    @Test func unreadableDataGivesTheDefaults() {
        #expect(decode("not json") == PrompterSettings())
        #expect(decode("[1, 2, 3]") == PrompterSettings())
        // A value of the wrong type can't be decoded: everything falls back, as documented.
        #expect(decode(#"{"leadWords": "many"}"#) == PrompterSettings())
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = PrompterSettings()
        settings.asrEngine = .apple
        settings.useHotwords = false
        settings.keyBindings = [.space: .forward, .arrowUp: .back]
        let data = try JSONEncoder().encode(settings)
        #expect(PrompterSettings.decodeMergingDefaults(data) == settings)
    }

    @Test func androidDefaults() {
        let s = PrompterSettings()
        #expect(s.phraseMode == true)
        #expect(s.maxWords == 7)
        #expect(s.speechLanguage == "auto")
        #expect(s.asrEngine == .sherpa)
        #expect(s.useHotwords == true)
        #expect(s.leadWords == 1)
        #expect(s.autoScrollWpm == 130)
        #expect(s.countdownSeconds == 3)
        #expect(s.keyControl == true)
    }
}

@Suite struct KeyBindingsTests {
    /// Android's `KeyBindings.DEFAULT` by action, with the iOS input each Android key becomes. Keys with no iOS
    /// counterpart (headset hook, D-pad centre, gamepad A, media play/pause/fast-forward/rewind) are listed apart.
    private static let androidPause: Set<HardwareKey> = [.captureSecondary, .mediaPlayPause, .space, .enter]
    private static let androidBack: Set<HardwareKey> = [.capturePrimary, .mediaPrevious, .pageUp, .arrowUp, .arrowLeft]
    private static let androidForward: Set<HardwareKey> = [.mediaNext, .pageDown, .arrowDown, .arrowRight]
    private static let pictureInPicture: [HardwareKey: KeyAction] = [
        .pipPlayPause: .pause, .pipSkipBack: .back, .pipSkipForward: .forward,
    ]

    private func keys(for action: KeyAction) -> Set<HardwareKey> {
        Set(KeyBindings.default.filter { $0.value == action }.keys)
    }

    @Test func pauseKeys() {
        #expect(keys(for: .pause) == Self.androidPause.union([.pipPlayPause]))
    }

    @Test func backKeys() {
        #expect(keys(for: .back) == Self.androidBack.union([.pipSkipBack]))
    }

    @Test func forwardKeys() {
        #expect(keys(for: .forward) == Self.androidForward.union([.pipSkipForward]))
    }

    @Test func volumeKeysAndPictureInPictureButtons() {
        // Android: volume up pauses, volume down goes back.
        #expect(KeyBindings.default[.captureSecondary] == .pause)
        #expect(KeyBindings.default[.capturePrimary] == .back)
        for (key, action) in Self.pictureInPicture { #expect(KeyBindings.default[key] == action) }
        #expect(KeyBindings.default.count == 16)
    }
}
