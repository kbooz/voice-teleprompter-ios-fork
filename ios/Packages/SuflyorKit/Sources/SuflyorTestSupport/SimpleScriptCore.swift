import Foundation
import SuflyorDomain

/// A small stand-in for the Kotlin core, for tests and previews: words split on spaces, and a naive follower that
/// advances when the heard words match the next few script words. It is NOT the real tracker.
public struct SimpleScriptCore: ScriptCoreProviding {
    public init() {}

    public func detectLanguage(_ paragraphs: [ScriptParagraph]) -> SpeechLanguage {
        let hasCyrillic = paragraphs.contains { p in p.text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
        return hasCyrillic ? .ru : .en
    }

    public func parseMarkdown(_ text: String, title: String) -> [ScriptParagraph] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return ScriptParagraph(text: heading, kind: .heading)
            }
            return ScriptParagraph(text: line)
        }
    }

    public func prepare(
        title: String,
        paragraphs: [ScriptParagraph],
        language: SpeechLanguage,
        phraseMode: Bool,
        maxWords: Int
    ) -> PreparedScript {
        var lines: [String] = []
        for paragraph in paragraphs {
            let words = paragraph.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            if phraseMode, maxWords > 0, words.count > maxWords {
                var index = 0
                while index < words.count {
                    lines.append(words[index ..< min(index + maxWords, words.count)].joined(separator: " "))
                    index += maxWords
                }
            } else if !words.isEmpty {
                lines.append(words.joined(separator: " "))
            }
        }
        let displayText = lines.joined(separator: "\n")
        let (tokens, notes) = Self.tokenize(displayText)
        let ns = displayText as NSString
        var bias: [String] = []
        for token in tokens where token.spoken {
            let word = Self.normalize(ns.substring(with: NSRange(location: token.start, length: token.end - token.start)))
            if word.count >= 4, !bias.contains(word) { bias.append(word) }
        }
        return PreparedScript(
            title: title,
            language: language,
            displayText: displayText,
            tokens: tokens,
            emphasis: [],
            notes: notes,
            spokenWords: tokens.filter(\.spoken).count,
            biasWords: bias,
            hotwords: bias.joined(separator: "/"),
            handle: CoreHandle(NSObject())
        )
    }

    public func makeFollower(for script: PreparedScript) -> any ScriptFollowing {
        SimpleFollower(script: script)
    }

    // MARK: - Helpers shared with the follower

    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Words split on whitespace in UTF-16 offsets; words inside `[ ... ]` are notes (shown, never spoken).
    static func tokenize(_ text: String) -> ([ScriptToken], [TextRange]) {
        let ns = text as NSString
        var tokens: [ScriptToken] = []
        var notes: [TextRange] = []
        var depth = 0
        var noteStart = 0
        var i = 0
        let n = ns.length
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 9 }
        while i < n {
            while i < n, isSpace(ns.character(at: i)) { i += 1 }
            let start = i
            while i < n, !isSpace(ns.character(at: i)) { i += 1 }
            guard i > start else { continue }
            let word = ns.substring(with: NSRange(location: start, length: i - start))
            let opens = word.hasPrefix("[")
            if opens, depth == 0 { noteStart = start }
            if opens { depth += 1 }
            tokens.append(ScriptToken(start: start, end: i, spoken: depth == 0))
            if word.hasSuffix("]"), depth > 0 {
                depth -= 1
                if depth == 0 { notes.append(TextRange(start: noteStart, end: i)) }
            }
        }
        return (tokens, notes)
    }
}

/// Advances while the heard words match one of the next three script words. Not thread-safe, like the real one.
final class SimpleFollower: ScriptFollowing {
    private let script: PreparedScript
    private let spokenTokens: [Int] // token index of each spoken word
    private let words: [String] // normalized spoken words
    private var pos = 0
    private var displayPos = 0

    init(script: PreparedScript) {
        self.script = script
        let ns = script.displayText as NSString
        var indices: [Int] = []
        var normalized: [String] = []
        for (i, token) in script.tokens.enumerated() where token.spoken {
            indices.append(i)
            normalized.append(SimpleScriptCore.normalize(ns.substring(with: NSRange(location: token.start, length: token.end - token.start))))
        }
        spokenTokens = indices
        words = normalized
    }

    var position: Int { pos }
    var size: Int { words.count }
    var nextToken: Int { tokenIndex(at: displayPos) }

    private func tokenIndex(at p: Int) -> Int {
        p >= spokenTokens.count ? script.tokens.count : spokenTokens[max(p, 0)]
    }

    private func update(moved: Bool, reason: String) -> FollowUpdate {
        FollowUpdate(moved: moved, position: pos, nextToken: nextToken, matches: moved ? 1 : 0, score: 1, reason: reason)
    }

    func onRecognized(text: String, isFinal: Bool, voiceActive: Bool, leadWords: Int, nowMillis: Int64) -> FollowUpdate {
        guard voiceActive else { return update(moved: false, reason: "idle") }
        let before = pos
        let heard = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { SimpleScriptCore.normalize(String($0)) }
        var p = pos
        for word in heard where !word.isEmpty {
            for k in p ..< min(p + 3, words.count) where words[k] == word {
                p = k + 1
                break
            }
        }
        pos = p
        // The lead only shows while the reader is still talking (a partial result).
        let lead = isFinal ? 0 : leadWords
        if pos < before { displayPos = pos }
        displayPos = min(max(displayPos, min(pos + lead, words.count)), pos + leadWords)
        return update(moved: pos != before, reason: pos != before ? "follow" : "no new words")
    }

    func jump(toToken tokenIndex: Int) -> FollowUpdate {
        pos = spokenTokens.firstIndex { $0 >= tokenIndex } ?? spokenTokens.count
        displayPos = pos
        return update(moved: true, reason: "manual")
    }

    /// Same rules as Android's `SessionEngine.stepLine`: back goes to the start of the current line first.
    func stepLine(_ delta: Int) -> FollowUpdate? {
        let ns = script.displayText as NSString
        var firsts: [Int] = []
        var lastLineStart = -1
        for (i, token) in script.tokens.enumerated() where token.spoken {
            var lineStart = token.start
            while lineStart > 0, ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
            if lineStart != lastLineStart {
                firsts.append(i)
                lastLineStart = lineStart
            }
        }
        guard !firsts.isEmpty else { return nil }
        let cur = tokenIndex(at: pos)
        let line = firsts.lastIndex { $0 <= cur } ?? -1
        let target: Int
        if delta < 0, line < 0 {
            target = firsts[0]
        } else if delta < 0, firsts[line] < cur {
            target = firsts[line]
        } else if delta < 0 {
            target = firsts[max(line + delta, 0)]
        } else if line + delta >= firsts.count {
            return nil
        } else {
            target = firsts[max(line + delta, 0)]
        }
        if target == cur { return nil }
        return jump(toToken: target)
    }

    func restart() -> FollowUpdate {
        pos = 0
        displayPos = 0
        return update(moved: true, reason: "manual")
    }
}
