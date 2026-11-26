import Foundation
import SuflyorCore
import SuflyorDomain

/// Adapts the shared Kotlin core (`SuflyorCore.xcframework`) to the `ScriptCoreProviding` contract.
///
/// Kotlin strings are UTF-16, like `String.utf16` and `NSRange`, so every offset maps one to one. The work left is
/// `Int` <-> `Int32` and dropping ranges the Kotlin side would reject (negative, empty or past the end of the text).
struct KMPScriptCore: ScriptCoreProviding {
    // VERIFY: the Swift names of the Kotlin export (SuflyorCore.shared, labels, Int32 types) match the generated header.
    // VERIFY: if `SuflyorCore.shared` resolves to the module, add `typealias KCore = SuflyorCore.SuflyorCore`.
    init() {}

    func detectLanguage(_ paragraphs: [ScriptParagraph]) -> SpeechLanguage {
        let code = SuflyorCore.shared.detectLanguage(paragraphs: paragraphs.map(Self.toCore))
        // Unknown code: Android falls back to Russian too.
        return SpeechLanguage(code: code) ?? .ru
    }

    func parseMarkdown(_ text: String, title: String) -> [ScriptParagraph] {
        SuflyorCore.shared.parseMarkdown(text: text, title: title).map(Self.paragraphFromCore)
    }

    func prepare(
        title: String,
        paragraphs: [ScriptParagraph],
        language: SpeechLanguage,
        phraseMode: Bool,
        maxWords: Int
    ) -> PreparedScript {
        let script = SuflyorCore.shared.buildScript(
            title: title,
            paragraphs: paragraphs.map(Self.toCore),
            langCode: language.code,
            phraseMode: phraseMode,
            maxWords: Int32(clamping: maxWords)
        )
        return PreparedScript(
            title: script.title,
            language: SpeechLanguage(code: script.langCode) ?? language,
            displayText: script.displayText,
            tokens: script.tokens.map {
                ScriptToken(start: Int($0.start), end: Int($0.endExclusive), spoken: $0.spoken)
            },
            emphasis: script.emphasis.map(Self.rangeFromCore),
            notes: script.notes.map(Self.rangeFromCore),
            spokenWords: Int(script.spokenWords),
            biasWords: script.biasWords(),
            hotwords: script.hotwords(),
            handle: CoreHandle(script)
        )
    }

    func makeFollower(for script: PreparedScript) -> any ScriptFollowing {
        // A handle from another core (a test double) can't be followed by this one: that is a programming error.
        guard let coreScript = script.handle.object as? CoreScript else {
            preconditionFailure("PreparedScript was not made by KMPScriptCore")
        }
        return KMPFollower(core: coreScript.newFollower())
    }

    // MARK: - Mapping

    private static func toCore(_ paragraph: ScriptParagraph) -> CoreParagraph {
        let length = paragraph.text.utf16.count
        let ranges = paragraph.emphasis.compactMap { range -> CoreRange? in
            guard range.start >= 0, range.end > range.start, range.end <= length else { return nil }
            return CoreRange(start: Int32(clamping: range.start), endExclusive: Int32(clamping: range.end))
        }
        return CoreParagraph(text: paragraph.text, heading: paragraph.kind == .heading, emphasis: ranges)
    }

    private static func paragraphFromCore(_ paragraph: CoreParagraph) -> ScriptParagraph {
        ScriptParagraph(
            text: paragraph.text,
            kind: paragraph.heading ? .heading : .body,
            emphasis: paragraph.emphasis.map(rangeFromCore)
        )
    }

    private static func rangeFromCore(_ range: CoreRange) -> TextRange {
        TextRange(start: Int(range.start), end: Int(range.endExclusive))
    }
}

/// `CoreFollower` behind the `ScriptFollowing` contract. Not thread-safe, like the Kotlin class: the session actor
/// is its only caller.
final class KMPFollower: ScriptFollowing {
    private let core: CoreFollower

    init(core: CoreFollower) {
        self.core = core
    }

    var position: Int { Int(core.position) }
    var nextToken: Int { Int(core.nextToken) }
    var size: Int { Int(core.size) }

    func onRecognized(text: String, isFinal: Bool, voiceActive: Bool, leadWords: Int, nowMillis: Int64) -> FollowUpdate {
        Self.map(core.onRecognized(
            text: text,
            isFinal: isFinal,
            voiceActive: voiceActive,
            leadWords: Int32(clamping: leadWords),
            nowMillis: nowMillis
        ))
    }

    func jump(toToken tokenIndex: Int) -> FollowUpdate {
        Self.map(core.jumpToToken(tokenIndex: Int32(clamping: tokenIndex)))
    }

    func stepLine(_ delta: Int) -> FollowUpdate? {
        core.stepLine(delta: Int32(clamping: delta)).map(Self.map)
    }

    func restart() -> FollowUpdate {
        Self.map(core.restart())
    }

    private static func map(_ update: CoreFollowUpdate) -> FollowUpdate {
        FollowUpdate(
            moved: update.moved,
            position: Int(update.position),
            nextToken: Int(update.nextToken),
            matches: Int(update.matches),
            score: update.score,
            reason: update.reason
        )
    }
}
