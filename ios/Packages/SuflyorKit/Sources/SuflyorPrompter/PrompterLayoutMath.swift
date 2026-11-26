import Foundation
import SuflyorDomain

/// Layout and hit-test arithmetic of the prompter, free of UIKit and Core Text so it can be unit-tested anywhere.
///
/// Every text offset is a UTF-16 code unit offset into `PreparedScript.displayText` (the unit the Kotlin core uses), so
/// an emoji counts as two units. The renderer feeds this the line starts it got from Core Text; the math never
/// measures glyphs itself.
public enum PrompterLayoutMath {
    /// Android's `PrompterView.LINE_SPACING`: the extra room goes below the glyphs.
    public static let lineSpacing: Double = 1.12
    /// Time constant of the exponential scroll smoothing (Android `SMOOTH_MS`).
    public static let smoothMs: Double = 150
    /// How long a manual drag keeps the text where the finger left it (Android `MANUAL_HOLD_MS`).
    public static let manualHoldMs: Double = 3000
    /// Read lines are drawn at this opacity (Android: white at alpha 95/255).
    public static let readLineAlpha: Double = 95.0 / 255.0

    // MARK: Lines

    /// UTF-16 offsets where each newline-separated line starts. Always begins with 0; a trailing newline yields a
    /// final empty line, as a text layout would.
    public static func hardLineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    /// Index of the line holding `offset`: the last line starting at or before it. Offsets outside the text clamp to
    /// the first or last line. `lineStarts` must be ascending.
    public static func lineIndex(forOffset offset: Int, lineStarts: [Int]) -> Int {
        guard lineStarts.count > 1 else { return 0 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// End (exclusive, UTF-16) of line `line`: where the next one starts, or the end of the text.
    public static func lineEnd(_ line: Int, lineStarts: [Int], textLength: Int) -> Int {
        line + 1 < lineStarts.count ? lineStarts[line + 1] : textLength
    }

    // MARK: Reading position

    public struct ReadSplit: Equatable, Sendable {
        /// The line the next word to read is on (the last line at the end of the script).
        public var currentLine: Int
        /// Everything before this UTF-16 offset is read and drawn dimmed.
        public var dimEnd: Int
        /// The script is finished: every word is read.
        public var atEnd: Bool
    }

    /// Which lines are read and which one is current for `nextToken`, as Android's `applyProgress` decides it.
    public static func readSplit(
        nextToken: Int,
        tokens: [ScriptToken],
        lineStarts: [Int],
        textLength: Int
    ) -> ReadSplit {
        let lastLine = max(0, lineStarts.count - 1)
        let index = max(0, nextToken)
        if index >= tokens.count {
            return ReadSplit(currentLine: lastLine, dimEnd: textLength, atEnd: true)
        }
        let line = lineIndex(forOffset: tokens[index].start, lineStarts: lineStarts)
        return ReadSplit(currentLine: line, dimEnd: lineStarts.isEmpty ? 0 : lineStarts[line], atEnd: false)
    }

    /// Scroll offset that puts line `line` `linesAbove` lines below the top of the text area (never negative).
    public static func scrollTarget(line: Int, linesAbove: Double, lineHeight: Double) -> Double {
        max(0, Double(line) * lineHeight - linesAbove * lineHeight)
    }

    /// One animation step towards `target`, frame-rate independent (Android's `1 - exp(-dt / SMOOTH_MS)`).
    /// Snaps when closer than half a point.
    public static func smoothed(current: Double, target: Double, dtMs: Double) -> Double {
        let k = 1 - exp(-max(0, dtMs) / smoothMs)
        let next = current + (target - current) * k
        return abs(target - next) < 0.5 ? target : next
    }

    /// Lines that intersect a viewport of `viewportHeight` starting `scroll` below the top of the text.
    public static func visibleLines(lineCount: Int, lineHeight: Double, scroll: Double, viewportHeight: Double) -> Range<Int> {
        guard lineCount > 0, lineHeight > 0 else { return 0..<0 }
        let first = max(0, Int((scroll / lineHeight).rounded(.down)))
        let last = min(lineCount - 1, Int(((scroll + viewportHeight) / lineHeight).rounded(.down)))
        return first <= last ? first..<(last + 1) : 0..<0
    }

    // MARK: Margins

    /// Left and right margins actually used: together they may take at most two thirds of the width, or the text
    /// would vanish in a narrow band (Android `rebuildLayout`).
    public static func effectiveSideMargins(start: Double, end: Double, width: Double) -> (left: Double, right: Double) {
        let sides = start + end
        let maxSides = width - width / 3
        let scale = (sides > maxSides && sides > 0) ? maxSides / sides : 1
        return (start * scale, end * scale)
    }

    // MARK: Taps

    /// Token under a tap, from the line that was hit and the character offset the tap fell on.
    ///
    /// The word under the finger, staying on the tapped line: the end of a word or the empty space right of a line
    /// must not select the next word or line (same rule as Android). Nil when the script has no token.
    public static func tokenIndex(
        forTapOnLine line: Int,
        characterOffset offset: Int,
        tokens: [ScriptToken],
        lineStarts: [Int],
        textLength: Int
    ) -> Int? {
        guard !tokens.isEmpty, !lineStarts.isEmpty else { return nil }
        let line = min(max(0, line), lineStarts.count - 1)
        let start = lineStarts[line]
        let end = lineEnd(line, lineStarts: lineStarts, textLength: textLength)
        var firstOnLine: Int?
        var lastBeforeOffset: Int?
        for (i, token) in tokens.enumerated() where token.start >= start && token.start < end {
            if firstOnLine == nil { firstOnLine = i }
            if token.start <= offset { lastBeforeOffset = i }
        }
        if let hit = lastBeforeOffset ?? firstOnLine { return hit }
        return tokens.firstIndex { $0.end > offset }
    }

    /// Maps a touch on the mirrored picture back onto the text as laid out.
    public static func unmirrored(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        mirrorX: Bool,
        mirrorY: Bool
    ) -> (x: Double, y: Double) {
        (mirrorX ? width - x : x, mirrorY ? height - y : y)
    }

    // MARK: Direction

    /// True when the first letter with a direction is Hebrew, Arabic, Syriac, Thaana, N'Ko or an RTL presentation
    /// form: the line starts on the right, and the reading mark goes there.
    public static func isRightToLeft(_ units: some Collection<UInt16>) -> Bool {
        for unit in units {
            if isRightToLeftUnit(unit) { return true }
            if isLeftToRightLetter(unit) { return false }
        }
        return false
    }

    public static func isRightToLeft(_ text: String) -> Bool {
        isRightToLeft(text.utf16)
    }

    private static func isRightToLeftUnit(_ u: UInt16) -> Bool {
        (0x0590...0x08FF).contains(u) || (0xFB1D...0xFDFF).contains(u) || (0xFE70...0xFEFF).contains(u)
    }

    private static func isLeftToRightLetter(_ u: UInt16) -> Bool {
        // Latin, Greek, Cyrillic, Armenian, CJK and Hangul: the scripts the app's languages use besides RTL ones.
        (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) || (0xC0...0x058F).contains(u)
            || (0x0900...0x1FFF).contains(u) || (0x2C00...0xD7FF).contains(u)
    }
}
