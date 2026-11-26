import SuflyorDomain
import Testing

@testable import SuflyorPrompter

/// Builds tokens for the words of `text` (split on spaces and newlines) in UTF-16 offsets, as the core would.
private func tokens(of text: String) -> [ScriptToken] {
    var result: [ScriptToken] = []
    var offset = 0
    var wordStart: Int?
    for unit in text.utf16 {
        let isSeparator = unit == 0x20 || unit == 0x0A
        if isSeparator {
            if let start = wordStart { result.append(ScriptToken(start: start, end: offset, spoken: true)) }
            wordStart = nil
        } else if wordStart == nil {
            wordStart = offset
        }
        offset += 1
    }
    if let start = wordStart { result.append(ScriptToken(start: start, end: offset, spoken: true)) }
    return result
}

@Suite("PrompterLayoutMath lines")
struct LineTests {
    @Test func hardLineStartsCountUTF16Units() {
        // "😀" is two UTF-16 units: the second line starts at 3 + 1, not 1 + 1.
        let text = "😀 a\nbc\n\nd"
        #expect(PrompterLayoutMath.hardLineStarts(of: text) == [0, 5, 8, 9])
    }

    @Test func hardLineStartsOfEmptyAndTrailingNewline() {
        #expect(PrompterLayoutMath.hardLineStarts(of: "") == [0])
        #expect(PrompterLayoutMath.hardLineStarts(of: "ab\n") == [0, 3])
    }

    @Test func lineIndexFindsLastLineStartingAtOrBefore() {
        let starts = [0, 5, 8, 9]
        #expect(PrompterLayoutMath.lineIndex(forOffset: 0, lineStarts: starts) == 0)
        #expect(PrompterLayoutMath.lineIndex(forOffset: 4, lineStarts: starts) == 0)
        #expect(PrompterLayoutMath.lineIndex(forOffset: 5, lineStarts: starts) == 1)
        #expect(PrompterLayoutMath.lineIndex(forOffset: 8, lineStarts: starts) == 2)
        #expect(PrompterLayoutMath.lineIndex(forOffset: 100, lineStarts: starts) == 3)
        #expect(PrompterLayoutMath.lineIndex(forOffset: -3, lineStarts: starts) == 0)
    }

    @Test func lineIndexOnDegenerateInput() {
        #expect(PrompterLayoutMath.lineIndex(forOffset: 3, lineStarts: []) == 0)
        #expect(PrompterLayoutMath.lineIndex(forOffset: 3, lineStarts: [0]) == 0)
    }

    @Test func emojiTokenSitsOnTheRightLine() {
        let text = "😀😀 hello\nworld 🎉"
        let toks = tokens(of: text)
        let starts = PrompterLayoutMath.hardLineStarts(of: text)
        // "😀😀" = 4 units, space, "hello" = 5..10, newline at 10, "world" starts at 11.
        #expect(starts == [0, 11])
        #expect(toks.map(\.start) == [0, 5, 11, 17])
        #expect(PrompterLayoutMath.lineIndex(forOffset: toks[1].start, lineStarts: starts) == 0)
        #expect(PrompterLayoutMath.lineIndex(forOffset: toks[2].start, lineStarts: starts) == 1)
        #expect(PrompterLayoutMath.lineIndex(forOffset: toks[3].start, lineStarts: starts) == 1)
    }
}

@Suite("PrompterLayoutMath reading position")
struct ReadSplitTests {
    private let text = "one two\nthree four\nfive"

    @Test func currentLineAndDimmedPrefix() {
        let toks = tokens(of: text)
        let starts = PrompterLayoutMath.hardLineStarts(of: text)
        let length = text.utf16.count

        let first = PrompterLayoutMath.readSplit(nextToken: 0, tokens: toks, lineStarts: starts, textLength: length)
        #expect(first == .init(currentLine: 0, dimEnd: 0, atEnd: false))

        // "three" is token 2: line 1 starts at 8.
        let second = PrompterLayoutMath.readSplit(nextToken: 2, tokens: toks, lineStarts: starts, textLength: length)
        #expect(second == .init(currentLine: 1, dimEnd: 8, atEnd: false))

        // Mid-line: "four" is on line 1 too, the whole line stays bright.
        let mid = PrompterLayoutMath.readSplit(nextToken: 3, tokens: toks, lineStarts: starts, textLength: length)
        #expect(mid == .init(currentLine: 1, dimEnd: 8, atEnd: false))
    }

    @Test func pastTheEndDimsEverything() {
        let toks = tokens(of: text)
        let starts = PrompterLayoutMath.hardLineStarts(of: text)
        let length = text.utf16.count
        let done = PrompterLayoutMath.readSplit(nextToken: toks.count, tokens: toks, lineStarts: starts, textLength: length)
        #expect(done == .init(currentLine: 2, dimEnd: length, atEnd: true))
    }

    @Test func negativeTokenCountsAsTheFirst() {
        let toks = tokens(of: text)
        let starts = PrompterLayoutMath.hardLineStarts(of: text)
        let split = PrompterLayoutMath.readSplit(nextToken: -4, tokens: toks, lineStarts: starts, textLength: text.utf16.count)
        #expect(split.currentLine == 0)
        #expect(!split.atEnd)
    }

    @Test func scrollTargetKeepsLinesAboveAndNeverGoesNegative() {
        #expect(PrompterLayoutMath.scrollTarget(line: 10, linesAbove: 1.5, lineHeight: 40) == 340)
        #expect(PrompterLayoutMath.scrollTarget(line: 1, linesAbove: 1.5, lineHeight: 40) == 0)
        #expect(PrompterLayoutMath.scrollTarget(line: 5, linesAbove: 0, lineHeight: 30) == 150)
    }

    @Test func smoothingApproachesAndSnaps() {
        let step = PrompterLayoutMath.smoothed(current: 0, target: 100, dtMs: 150)
        // One time constant covers 1 - 1/e of the way.
        #expect(abs(step - 63.2) < 0.2)
        #expect(PrompterLayoutMath.smoothed(current: 99.8, target: 100, dtMs: 16) == 100)
        #expect(PrompterLayoutMath.smoothed(current: 50, target: 50, dtMs: 16) == 50)
    }

    @Test func visibleLinesCoverTheViewport() {
        // 10 lines of 20 pt, viewport 50 pt starting at 30: lines 1...3.
        let range = PrompterLayoutMath.visibleLines(lineCount: 10, lineHeight: 20, scroll: 30, viewportHeight: 50)
        #expect(range == 1..<5)
        #expect(PrompterLayoutMath.visibleLines(lineCount: 0, lineHeight: 20, scroll: 0, viewportHeight: 50).isEmpty)
        #expect(PrompterLayoutMath.visibleLines(lineCount: 3, lineHeight: 20, scroll: 500, viewportHeight: 50).isEmpty)
    }

    @Test func marginsShrinkTogetherWhenTheyLeaveTooLittleRoom() {
        let roomy = PrompterLayoutMath.effectiveSideMargins(start: 20, end: 10, width: 300)
        #expect(roomy.left == 20 && roomy.right == 10)
        // Together at most two thirds of 300 = 200 (so 100 of text remains): 150 + 150 → 100 + 100.
        let squeezed = PrompterLayoutMath.effectiveSideMargins(start: 150, end: 150, width: 300)
        #expect(abs(squeezed.left - 100) < 0.001 && abs(squeezed.right - 100) < 0.001)
    }
}

@Suite("PrompterLayoutMath taps")
struct TapTests {
    // Line starts: 0 "alpha beta", 11 "gamma delta", 23 "" (empty), 24 "omega".
    private let text = "alpha beta\ngamma delta\n\nomega"

    private var toks: [ScriptToken] { tokens(of: text) }
    private var starts: [Int] { PrompterLayoutMath.hardLineStarts(of: text) }
    private var length: Int { text.utf16.count }

    private func hit(line: Int, offset: Int) -> Int? {
        PrompterLayoutMath.tokenIndex(
            forTapOnLine: line, characterOffset: offset, tokens: toks, lineStarts: starts, textLength: length
        )
    }

    @Test func tapInsideAWordSelectsIt() {
        #expect(hit(line: 0, offset: 2) == 0)
        #expect(hit(line: 0, offset: 8) == 1)
        #expect(hit(line: 1, offset: 13) == 2)
    }

    @Test func tapAtTheEndOfALineStaysOnItsLastWord() {
        // The offset past "beta" is the newline: must not select "gamma" on the next line.
        #expect(hit(line: 0, offset: 10) == 1)
        #expect(hit(line: 0, offset: 11) == 1)
    }

    @Test func tapLeftOfTheFirstWordSelectsTheFirstWordOfTheLine() {
        #expect(hit(line: 1, offset: 11) == 2)
        #expect(hit(line: 1, offset: 5) == 2)
    }

    @Test func tapOnAnEmptyLineFallsForwardToTheNextWord() {
        // Line 2 is empty: nothing on it, so the first token ending after the offset wins.
        #expect(hit(line: 2, offset: 23) == 4)
    }

    @Test func lineIndexIsClamped() {
        #expect(hit(line: -5, offset: 0) == 0)
        #expect(hit(line: 99, offset: 26) == 4)
    }

    @Test func noTokensNoHit() {
        let none = PrompterLayoutMath.tokenIndex(forTapOnLine: 0, characterOffset: 0, tokens: [], lineStarts: [0], textLength: 0)
        #expect(none == nil)
    }

    @Test func emojiOffsetsAreInUTF16Units() {
        let emojiText = "😀 ok\nnext"
        let toks = tokens(of: emojiText)
        let starts = PrompterLayoutMath.hardLineStarts(of: emojiText)
        let length = emojiText.utf16.count
        // "😀" is units 0...1, "ok" starts at 3. A tap that lands at unit 4 is inside "ok".
        let ok = PrompterLayoutMath.tokenIndex(
            forTapOnLine: 0, characterOffset: 4, tokens: toks, lineStarts: starts, textLength: length
        )
        #expect(ok == 1)
        // A tap on the emoji's second unit still selects the emoji token, not "ok".
        let emoji = PrompterLayoutMath.tokenIndex(
            forTapOnLine: 0, characterOffset: 1, tokens: toks, lineStarts: starts, textLength: length
        )
        #expect(emoji == 0)
    }
}

@Suite("PrompterLayoutMath mirror and direction")
struct MirrorTests {
    @Test func unmirroredMapsBackOntoTheText() {
        let none = PrompterLayoutMath.unmirrored(x: 30, y: 20, width: 100, height: 80, mirrorX: false, mirrorY: false)
        #expect(none.x == 30 && none.y == 20)
        let horizontal = PrompterLayoutMath.unmirrored(x: 30, y: 20, width: 100, height: 80, mirrorX: true, mirrorY: false)
        #expect(horizontal.x == 70 && horizontal.y == 20)
        let vertical = PrompterLayoutMath.unmirrored(x: 30, y: 20, width: 100, height: 80, mirrorX: false, mirrorY: true)
        #expect(vertical.x == 30 && vertical.y == 60)
        let both = PrompterLayoutMath.unmirrored(x: 30, y: 20, width: 100, height: 80, mirrorX: true, mirrorY: true)
        #expect(both.x == 70 && both.y == 60)
    }

    @Test func mirroringTwiceIsTheIdentity() {
        let once = PrompterLayoutMath.unmirrored(x: 12, y: 7, width: 100, height: 80, mirrorX: true, mirrorY: true)
        let twice = PrompterLayoutMath.unmirrored(x: once.x, y: once.y, width: 100, height: 80, mirrorX: true, mirrorY: true)
        #expect(twice.x == 12 && twice.y == 7)
    }

    @Test func mirroredTapHitsTheWordThatIsDrawnThere() {
        // The word "beta" occupies x 60...100 of a 100 pt wide line. On the mirrored picture it is drawn at 0...40:
        // a tap at x = 10 on screen is a tap at x = 90 on the laid-out text.
        let onText = PrompterLayoutMath.unmirrored(x: 10, y: 5, width: 100, height: 20, mirrorX: true, mirrorY: false)
        #expect(onText.x == 90)
    }

    @Test func directionOfTheFirstLetterWins() {
        #expect(!PrompterLayoutMath.isRightToLeft("Hello"))
        #expect(PrompterLayoutMath.isRightToLeft("שלום"))
        #expect(PrompterLayoutMath.isRightToLeft("مرحبا"))
        // Digits and punctuation have no direction: the first letter decides.
        #expect(PrompterLayoutMath.isRightToLeft("1. שלום"))
        #expect(!PrompterLayoutMath.isRightToLeft("1. Hello שלום"))
        #expect(!PrompterLayoutMath.isRightToLeft(""))
        #expect(!PrompterLayoutMath.isRightToLeft("Привет"))
    }
}
