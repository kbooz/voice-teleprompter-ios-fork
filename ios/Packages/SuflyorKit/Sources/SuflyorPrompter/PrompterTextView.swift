import SuflyorDomain
import SwiftUI
import UIKit

/// The scrolling script: read lines dimmed, `[notes]` styled, emphasis bold, the next word kept on the reading line.
///
/// Tap a word to jump there (`onTapToken`); drag to look around, and following resumes a few seconds later (as on
/// Android). The text is drawn by `PrompterRenderer`, the same code that feeds the Picture in Picture window.
public struct PrompterTextView: View {
    private let script: PreparedScript
    private let nextToken: Int
    private let style: PrompterStyle
    private let onTapToken: ((Int) -> Void)?

    public init(script: PreparedScript, nextToken: Int, style: PrompterStyle, onTapToken: ((Int) -> Void)? = nil) {
        self.script = script
        self.nextToken = nextToken
        self.style = style
        self.onTapToken = onTapToken
    }

    public var body: some View {
        PrompterCanvas(script: script, nextToken: nextToken, style: style, onTapToken: onTapToken)
    }
}

private struct PrompterCanvas: UIViewRepresentable {
    let script: PreparedScript
    let nextToken: Int
    let style: PrompterStyle
    let onTapToken: ((Int) -> Void)?

    func makeUIView(context: Context) -> PrompterUIView {
        PrompterUIView()
    }

    func updateUIView(_ view: PrompterUIView, context: Context) {
        view.update(script: script, nextToken: nextToken, style: style, onTapToken: onTapToken)
    }
}

/// Owns the renderer, the scroll animation and the gestures.
@MainActor
final class PrompterUIView: UIView {
    private var renderer: PrompterRenderer?
    private var script: PreparedScript?
    private var style = PrompterStyle(fontSize: 26, visibleLines: 3, paddingStart: 18, paddingEnd: 14)
    private var nextToken = 0
    private var onTapToken: ((Int) -> Void)?

    private var scroll: Double = 0
    private var target: Double = 0
    /// Until this `CACurrentMediaTime()` the text stays where a drag left it.
    private var manualUntil: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = [.updatesFrequently]
        accessibilityLabel = L10n.text("ios_prompter_title")
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Updates from SwiftUI

    func update(script: PreparedScript, nextToken: Int, style: PrompterStyle, onTapToken: ((Int) -> Void)?) {
        self.onTapToken = onTapToken
        let scriptChanged = self.script?.handle !== script.handle || renderer == nil
        let layoutChanged = style.fontSize != self.style.fontSize
            || style.paddingStart != self.style.paddingStart
            || style.paddingEnd != self.style.paddingEnd
            || style.topInset != self.style.topInset
            || style.linesAbove != self.style.linesAbove
        let styleChanged = style != self.style
        self.style = style
        if scriptChanged {
            self.script = script
            renderer = PrompterRenderer(script: script)
            accessibilityValue = script.title
        }
        let tokenChanged = nextToken != self.nextToken
        self.nextToken = nextToken
        guard bounds.width > 0, let renderer else {
            setNeedsDisplay()
            return
        }
        renderer.configure(style: style, size: bounds.size)
        target = renderer.targetOffset(nextToken: nextToken, linesAbove: style.linesAbove)
        if scriptChanged || layoutChanged {
            // A new layout has other line positions: jump, don't glide from the old ones.
            scroll = target
        } else if tokenChanged {
            startAnimating()
        }
        if scriptChanged || styleChanged || tokenChanged { setNeedsDisplay() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize, bounds.width > 0, let renderer else { return }
        laidOutSize = bounds.size
        renderer.configure(style: style, size: bounds.size)
        target = renderer.targetOffset(nextToken: nextToken, linesAbove: style.linesAbove)
        scroll = target
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopAnimating() }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let renderer, let ctx = UIGraphicsGetCurrentContext() else { return }
        renderer.draw(in: ctx, size: bounds.size, scrollOffset: scroll, nextToken: nextToken, style: style)
    }

    // MARK: Animation

    private func startAnimating() {
        if UIAccessibility.isReduceMotionEnabled, CACurrentMediaTime() >= manualUntil {
            scroll = target
            setNeedsDisplay()
            return
        }
        guard displayLink == nil, window != nil else {
            if window == nil { scroll = target }
            return
        }
        lastTick = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        lastTick = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dtMs = lastTick == 0 ? 16 : min(100, max(1, (now - lastTick) * 1000))
        lastTick = now
        let holding = CACurrentMediaTime() < manualUntil
        if !holding {
            scroll = PrompterLayoutMath.smoothed(current: scroll, target: target, dtMs: dtMs)
        }
        setNeedsDisplay()
        // Idle display links cost battery: stop once the text has settled.
        if scroll == target, !holding { stopAnimating() }
    }

    // MARK: Gestures

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let renderer else { return }
        let point = recognizer.location(in: self)
        if let index = renderer.tokenIndex(at: point, scrollOffset: scroll, style: style) {
            manualUntil = 0
            onTapToken?(index)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let renderer else { return }
        switch recognizer.state {
        case .changed:
            let dy = Double(recognizer.translation(in: self).y)
            recognizer.setTranslation(.zero, in: self)
            // On the mirrored picture the finger moves the opposite way through the text.
            let signed = style.mirrorVertical ? -dy : dy
            scroll = min(max(0, scroll - signed), max(0, renderer.contentHeight))
            manualUntil = CACurrentMediaTime() + PrompterLayoutMath.manualHoldMs / 1000
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            // The hold runs out and the text eases back to the reading line.
            startAnimating()
        default:
            break
        }
    }
}
