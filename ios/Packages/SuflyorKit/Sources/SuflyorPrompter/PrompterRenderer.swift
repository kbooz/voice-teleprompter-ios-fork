import CoreGraphics
import CoreText
import Foundation
import SuflyorDomain

/// Draws the script with Core Text into any `CGContext`: the on-screen view and the Picture in Picture frames use this
/// one renderer, so they look identical.
///
/// The context must have a top-left origin with y pointing down (UIKit's `draw(_:)` context already does; bitmap
/// contexts need a flip first). Not thread-safe: own it from one actor (the main one, in this module).
///
/// Lines are typeset by hand (one `CTTypesetter`, my own line breaking per newline-separated paragraph) instead of
/// with a `CTFrame`, so the line starts are exact UTF-16 offsets that `PrompterLayoutMath` can reason about, and every
/// line has the same height, like Android's `StaticLayout` with a spacing multiplier.
public final class PrompterRenderer {
    private struct Line {
        /// UTF-16 offset where the line starts.
        var start: Int
        /// Nil for an empty paragraph.
        var ct: CTLine?
        /// Horizontal shift inside the text width: 0 for left-to-right lines, flush right for right-to-left ones.
        var penX: CGFloat
        var rtl: Bool
    }

    private struct LayoutKey: Equatable {
        var width: Double
        var fontSize: Double
    }

    // Script
    private let text: String
    private let utf16: [UInt16]
    private let tokens: [ScriptToken]
    private let emphasis: [TextRange]
    private let notes: [TextRange]

    // Layout
    private var key: LayoutKey?
    private var lines: [Line] = []
    private var lineStarts: [Int] = [0]
    private(set) var textLeft: Double = 0
    private var textWidth: Double = 0
    private var ascent: Double = 0
    private var descent: Double = 0
    public private(set) var lineHeight: Double = 0
    private var size: CGSize = .zero

    // Instance constants: CGColor is not guaranteed Sendable, so no statics under Swift 6.
    private let accent = CGColor(red: 1, green: 176.0 / 255, blue: 32.0 / 255, alpha: 1)
    private let nextWordFill = CGColor(red: 1, green: 176.0 / 255, blue: 32.0 / 255, alpha: 120.0 / 255)
    private let noteColor = CGColor(red: 140.0 / 255, green: 200.0 / 255, blue: 1, alpha: 170.0 / 255)
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let textGlow = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)

    public init(script: PreparedScript) {
        text = script.displayText
        utf16 = Array(script.displayText.utf16)
        tokens = script.tokens
        emphasis = script.emphasis
        notes = script.notes
    }

    /// Height of one line at `fontSize`, without needing a script (the camera band is sized before the text is laid out).
    public static func lineHeight(forFontSize fontSize: Double) -> Double {
        let font = baseFont(fontSize)
        return Double(CTFontGetAscent(font) + CTFontGetDescent(font)) * PrompterLayoutMath.lineSpacing
    }

    // MARK: Layout

    public var lineCount: Int { lines.count }

    /// Total height of the text, for clamping manual drags.
    public var contentHeight: Double { Double(lines.count) * lineHeight }

    /// Lays the text out for `size` and `style` when something that changes line breaks has changed. Cheap otherwise.
    public func configure(style: PrompterStyle, size: CGSize) {
        self.size = size
        let margins = PrompterLayoutMath.effectiveSideMargins(
            start: style.paddingStart, end: style.paddingEnd, width: Double(size.width)
        )
        textLeft = margins.left
        let width = Double(size.width) - margins.left - margins.right
        textWidth = width
        let newKey = LayoutKey(width: width, fontSize: style.fontSize)
        guard newKey != key else { return }
        key = newKey
        rebuild(width: width, fontSize: style.fontSize)
    }

    private func rebuild(width: Double, fontSize: Double) {
        let font = Self.baseFont(fontSize)
        ascent = Double(CTFontGetAscent(font))
        descent = Double(CTFontGetDescent(font))
        lineHeight = (ascent + descent) * PrompterLayoutMath.lineSpacing
        lines = []
        guard width > 0 else {
            lineStarts = [0]
            return
        }
        let attributed = makeAttributedString(fontSize: fontSize)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
        let hardStarts = PrompterLayoutMath.hardLineStarts(of: text)
        let total = utf16.count
        for (h, paragraphStart) in hardStarts.enumerated() {
            let isLast = h + 1 == hardStarts.count
            // The newline belongs to the paragraph it ends but is never typeset.
            let paragraphEnd = isLast ? total : hardStarts[h + 1] - 1
            let rtl = PrompterLayoutMath.isRightToLeft(utf16[paragraphStart..<max(paragraphStart, paragraphEnd)])
            if paragraphEnd <= paragraphStart {
                lines.append(Line(start: paragraphStart, ct: nil, penX: 0, rtl: rtl))
                continue
            }
            var start = paragraphStart
            while start < paragraphEnd {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, width)
                if count <= 0 { count = 1 }
                count = min(count, paragraphEnd - start)
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                let pen = CTLineGetPenOffsetForFlush(line, rtl ? 1 : 0, width)
                lines.append(Line(start: start, ct: line, penX: CGFloat(pen), rtl: rtl))
                start += count
            }
        }
        lineStarts = lines.map(\.start)
        if lineStarts.isEmpty { lineStarts = [0] }
    }

    private static func baseFont(_ size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
    }

    private static func font(_ base: CTFont, size: Double, bold: Bool, italic: Bool) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits.isEmpty { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, traits, traits) ?? base
    }

    /// Emphasis is bold, `[notes]` are italic light blue (Android: `StyleSpan` + `ForegroundColorSpan(noteColor)`).
    private func makeAttributedString(fontSize: Double) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let base = Self.baseFont(fontSize)
        let result = NSMutableAttributedString(string: text, attributes: [fontKey: base, colorKey: white])
        let count = utf16.count
        guard count > 0 else { return result }

        // Bit 0: emphasis, bit 1: note. Runs of equal flags get one font each.
        var flags = [UInt8](repeating: 0, count: count)
        func mark(_ ranges: [TextRange], bit: UInt8) {
            for range in ranges {
                let lower = max(0, range.start)
                let upper = min(count, range.end)
                guard lower < upper else { continue }
                for i in lower..<upper { flags[i] |= bit }
            }
        }
        mark(emphasis, bit: 1)
        mark(notes, bit: 2)

        var i = 0
        while i < count {
            var j = i + 1
            while j < count, flags[j] == flags[i] { j += 1 }
            let flag = flags[i]
            if flag != 0 {
                let font = Self.font(base, size: fontSize, bold: flag & 1 != 0, italic: flag & 2 != 0)
                var attributes: [NSAttributedString.Key: Any] = [fontKey: font]
                if flag & 2 != 0 { attributes[colorKey] = noteColor }
                result.addAttributes(attributes, range: NSRange(location: i, length: j - i))
            }
            i = j
        }
        return result
    }

    // MARK: Position

    /// Scroll offset that puts the line of `nextToken` `linesAbove` lines below the top.
    public func targetOffset(nextToken: Int, linesAbove: Double) -> Double {
        let split = PrompterLayoutMath.readSplit(
            nextToken: nextToken, tokens: tokens, lineStarts: lineStarts, textLength: utf16.count
        )
        return PrompterLayoutMath.scrollTarget(line: split.currentLine, linesAbove: linesAbove, lineHeight: lineHeight)
    }

    // MARK: Drawing

    public func draw(in ctx: CGContext, size: CGSize, scrollOffset: Double, nextToken: Int, style: PrompterStyle) {
        configure(style: style, size: size)

        // The band behind the text is not mirrored: it is the whole picture.
        if style.backgroundOpacity > 0 {
            let alpha = CGFloat(min(max(style.backgroundOpacity, 0), 1))
            ctx.setFillColor(red: 8.0 / 255, green: 8.0 / 255, blue: 10.0 / 255, alpha: alpha)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard !lines.isEmpty, lineHeight > 0, textWidth > 0 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: CGRect(origin: .zero, size: size))
        if style.mirrorHorizontal || style.mirrorVertical {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: style.mirrorHorizontal ? -1 : 1, y: style.mirrorVertical ? -1 : 1)
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        }
        ctx.translateBy(x: CGFloat(textLeft), y: CGFloat(style.topInset - scrollOffset))

        let split = PrompterLayoutMath.readSplit(
            nextToken: nextToken, tokens: tokens, lineStarts: lineStarts, textLength: utf16.count
        )
        let visible = PrompterLayoutMath.visibleLines(
            lineCount: lines.count,
            lineHeight: lineHeight,
            scroll: scrollOffset - style.topInset,
            viewportHeight: Double(size.height)
        )
        if !split.atEnd, visible.contains(split.currentLine) { drawReadingMark(ctx, line: split.currentLine) }
        if style.wordHighlight, !split.atEnd, tokens.indices.contains(nextToken) {
            drawNextWord(ctx, token: tokens[nextToken], visible: visible)
        }
        let glow = style.backgroundOpacity < 0.85
        for index in visible {
            drawLine(ctx, index: index, dimmed: split.atEnd || index < split.currentLine, glow: glow)
        }
    }

    private func drawLine(_ ctx: CGContext, index: Int, dimmed: Bool, glow: Bool) {
        let line = lines[index]
        guard let ct = line.ct else { return }
        ctx.saveGState()
        if dimmed { ctx.setAlpha(CGFloat(PrompterLayoutMath.readLineAlpha)) }
        // A soft dark halo keeps white text readable over any camera picture. Zero offset: shadow offsets are not
        // flipped by the context, so a direction would depend on the context's origin.
        if glow { ctx.setShadow(offset: .zero, blur: 4, color: textGlow) }
        ctx.textMatrix = .identity
        ctx.translateBy(x: line.penX, y: CGFloat(Double(index) * lineHeight + ascent))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ct, ctx)
        ctx.restoreGState()
    }

    /// The amber bar where the current line starts (right of the text for right-to-left lines).
    private func drawReadingMark(_ ctx: CGContext, line index: Int) {
        let top = Double(index) * lineHeight
        let height = max(2, ascent + descent - 4)
        let barWidth = 3.5
        let x = lines[index].rtl ? textWidth + 9 - barWidth : -9
        let rect = CGRect(x: CGFloat(x), y: CGFloat(top + 3), width: CGFloat(barWidth), height: CGFloat(height))
        ctx.setFillColor(accent)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()
    }

    /// Amber background behind the next word, line by line in case the word wraps.
    private func drawNextWord(_ ctx: CGContext, token: ScriptToken, visible: Range<Int>) {
        ctx.setFillColor(nextWordFill)
        for index in visible {
            let line = lines[index]
            guard let ct = line.ct else { continue }
            let range = CTLineGetStringRange(ct)
            let from = max(token.start, range.location)
            let to = min(token.end, range.location + range.length)
            guard from < to else { continue }
            let x1 = CTLineGetOffsetForStringIndex(ct, from, nil)
            let x2 = CTLineGetOffsetForStringIndex(ct, to, nil)
            let rect = CGRect(
                x: line.penX + min(x1, x2),
                y: CGFloat(Double(index) * lineHeight),
                width: abs(x2 - x1),
                height: CGFloat(ascent + descent)
            )
            ctx.fill(rect)
        }
    }

    // MARK: Hit test

    /// The token under `point` (in the view's coordinates, so on the mirrored picture when mirroring is on).
    public func tokenIndex(at point: CGPoint, scrollOffset: Double, style: PrompterStyle) -> Int? {
        guard !lines.isEmpty, lineHeight > 0, size.width > 0 else { return nil }
        let p = PrompterLayoutMath.unmirrored(
            x: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height),
            mirrorX: style.mirrorHorizontal,
            mirrorY: style.mirrorVertical
        )
        let y = p.y - style.topInset + scrollOffset
        let row = min(max(Int((y / lineHeight).rounded(.down)), 0), lines.count - 1)
        let line = lines[row]
        var offset = line.start
        if let ct = line.ct {
            let index = CTLineGetStringIndexForPosition(ct, CGPoint(x: p.x - textLeft - Double(line.penX), y: 0))
            if index != kCFNotFound { offset = index }
        }
        return PrompterLayoutMath.tokenIndex(
            forTapOnLine: row,
            characterOffset: offset,
            tokens: tokens,
            lineStarts: lineStarts,
            textLength: utf16.count
        )
    }
}
