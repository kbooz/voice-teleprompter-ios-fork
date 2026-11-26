import Foundation

/// A word of `PreparedScript.displayText` (Kotlin: `script.Token`), in UTF-16 offsets.
public struct ScriptToken: Hashable, Sendable {
    public var start: Int
    public var end: Int
    /// False for `[stage directions]` and other text that is shown but never expected to be spoken.
    public var spoken: Bool

    public init(start: Int, end: Int, spoken: Bool) {
        self.start = start
        self.end = end
        self.spoken = spoken
    }
}

/// Opaque reference to the shared core's own object (a Kotlin `CoreScript`). Only the adapter that created it reads it.
public final class CoreHandle: @unchecked Sendable {
    public let object: AnyObject

    public init(_ object: AnyObject) {
        self.object = object
    }
}

/// A script laid out for the prompter and the tracker (Kotlin: `script.ScriptModel`, via `CoreScript`).
public struct PreparedScript: Sendable {
    public let title: String
    public let language: SpeechLanguage
    /// The text the prompter draws: paragraphs (and phrases in phrase mode) separated by newlines.
    public let displayText: String
    public let tokens: [ScriptToken]
    public let emphasis: [TextRange]
    public let notes: [TextRange]
    /// Spoken words (CJK: characters divided by units per word), for reading time.
    public let spokenWords: Int
    /// Script words to bias a recognizer towards (Apple engine: contextual strings).
    public let biasWords: [String]
    /// The same words encoded for sherpa-onnx hotwords (BPE-friendly, one per line); empty when the model can't use them.
    public let hotwords: String
    public let handle: CoreHandle

    public init(
        title: String,
        language: SpeechLanguage,
        displayText: String,
        tokens: [ScriptToken],
        emphasis: [TextRange],
        notes: [TextRange],
        spokenWords: Int,
        biasWords: [String],
        hotwords: String,
        handle: CoreHandle
    ) {
        self.title = title
        self.language = language
        self.displayText = displayText
        self.tokens = tokens
        self.emphasis = emphasis
        self.notes = notes
        self.spokenWords = spokenWords
        self.biasWords = biasWords
        self.hotwords = hotwords
        self.handle = handle
    }

    /// Reading time at `wpm` words per minute, rounded up (same formula as Android).
    public func durationSeconds(wpm: Int) -> Int {
        wpm <= 0 ? 0 : (spokenWords * 60 + wpm - 1) / wpm
    }
}

/// What a follower did with one recognizer update or manual move (Kotlin: `CoreFollowUpdate`).
public struct FollowUpdate: Hashable, Sendable {
    public var moved: Bool
    /// Position in spoken words (0 ..< size): the next word the tracker expects.
    public var position: Int
    /// Token index the prompter highlights as "next to read", including the lead that hides recognition latency.
    public var nextToken: Int
    public var matches: Int
    public var score: Float
    /// "follow", "near", "jump", "weak jump to …", "manual", … for the journal.
    public var reason: String

    public init(moved: Bool, position: Int, nextToken: Int, matches: Int, score: Float, reason: String) {
        self.moved = moved
        self.position = position
        self.nextToken = nextToken
        self.matches = matches
        self.score = score
        self.reason = reason
    }
}

/// Follows the reader through one script (Kotlin: `CoreFollower`, which wraps `ScriptTracker` plus the word history
/// and lead logic of Android's `SessionEngine.onAsr`). Not thread-safe: owned and called by the session actor only.
public protocol ScriptFollowing: AnyObject {
    /// Spoken-word position of the next expected word.
    var position: Int { get }
    /// Token index of the next word to read, with the lead applied.
    var nextToken: Int { get }
    /// Number of spoken words in the script.
    var size: Int { get }

    /// One recognizer update. `voiceActive` is "scroll mode is voice and the session is not paused": otherwise the
    /// words only go into the history and the position stays. `nowMillis` is a monotonic clock in milliseconds.
    func onRecognized(text: String, isFinal: Bool, voiceActive: Bool, leadWords: Int, nowMillis: Int64) -> FollowUpdate

    /// Manual move to a token (a tap on the text). Clears the recognized-word history.
    func jump(toToken tokenIndex: Int) -> FollowUpdate

    /// One displayed line back (`-1`) or forward (`+1`), as the remote keys do. Nil when there is nowhere to go.
    func stepLine(_ delta: Int) -> FollowUpdate?

    /// Back to the start of the script.
    func restart() -> FollowUpdate
}

/// The shared Kotlin core seen from Swift. The app target implements it over the `SuflyorCore` XCFramework
/// (`KMPScriptCore`); tests and previews use `SuflyorTestSupport.SimpleScriptCore`.
public protocol ScriptCoreProviding: Sendable {
    /// Picks the speech language from the script's letters (Kotlin: `SpeechLang.detect`).
    func detectLanguage(_ paragraphs: [ScriptParagraph]) -> SpeechLanguage

    /// Markdown / Obsidian / plain text with `**emphasis**`, `# headings` and `[notes]` (Kotlin: `MarkdownImporter.parse`).
    func parseMarkdown(_ text: String, title: String) -> [ScriptParagraph]

    /// Lays the script out (Kotlin: `ScriptLayout.build`). `phraseMode` splits long paragraphs into phrases of at most
    /// `maxWords` words.
    func prepare(
        title: String,
        paragraphs: [ScriptParagraph],
        language: SpeechLanguage,
        phraseMode: Bool,
        maxWords: Int
    ) -> PreparedScript

    /// A new follower positioned at the start of `script`.
    func makeFollower(for script: PreparedScript) -> any ScriptFollowing
}
