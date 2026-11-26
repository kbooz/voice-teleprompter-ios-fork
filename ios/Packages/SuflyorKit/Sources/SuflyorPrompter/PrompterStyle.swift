import CoreGraphics
import SuflyorDomain

/// How the script is drawn. The same value drives the on-screen view and the Picture in Picture frames.
public struct PrompterStyle: Hashable, Sendable {
    public var fontSize: Double
    /// 0 = as many as fit (full screen).
    public var visibleLines: Int
    /// Left margin of the text, points. Physical left, as on Android, whatever the script's direction.
    public var paddingStart: Double
    /// Right margin of the text, points.
    public var paddingEnd: Double
    public var wordHighlight: Bool
    /// 0...1, the dark band behind the text.
    public var backgroundOpacity: Double
    public var mirrorHorizontal: Bool
    public var mirrorVertical: Bool
    /// Lines of already-read text kept visible above the reading line (0 over the camera, 1.5 full screen).
    public var linesAbove: Double
    /// Space above the first line: the camera band puts the Dynamic Island's height here so the text starts under the lens.
    public var topInset: Double
    public var bottomInset: Double

    public static let defaultTopInset: Double = 4
    public static let defaultBottomInset: Double = 2

    public init(
        fontSize: Double,
        visibleLines: Int,
        paddingStart: Double,
        paddingEnd: Double,
        wordHighlight: Bool = false,
        backgroundOpacity: Double = 0.72,
        mirrorHorizontal: Bool = false,
        mirrorVertical: Bool = false,
        linesAbove: Double = 0,
        topInset: Double = PrompterStyle.defaultTopInset,
        bottomInset: Double = PrompterStyle.defaultBottomInset
    ) {
        self.fontSize = fontSize
        self.visibleLines = visibleLines
        self.paddingStart = paddingStart
        self.paddingEnd = paddingEnd
        self.wordHighlight = wordHighlight
        self.backgroundOpacity = backgroundOpacity
        self.mirrorHorizontal = mirrorHorizontal
        self.mirrorVertical = mirrorVertical
        self.linesAbove = linesAbove
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    /// The small window over the camera or in Picture in Picture (Android's overlay settings).
    public static func overCamera(_ settings: PrompterSettings) -> PrompterStyle {
        PrompterStyle(
            fontSize: settings.fontSize,
            visibleLines: settings.visibleLines,
            paddingStart: settings.paddingStart,
            paddingEnd: settings.paddingEnd,
            wordHighlight: settings.wordHighlight,
            backgroundOpacity: Double(min(max(settings.backgroundOpacity, 0), 100)) / 100,
            linesAbove: 0
        )
    }

    /// The rehearsal screen: whole screen, mirror for teleprompter glass, a line of read text above the reading line.
    public static func fullScreen(_ settings: PrompterSettings) -> PrompterStyle {
        PrompterStyle(
            fontSize: settings.fullScreenFontSize,
            visibleLines: 0,
            paddingStart: settings.fullScreenPaddingStart,
            paddingEnd: settings.fullScreenPaddingEnd,
            wordHighlight: settings.wordHighlight,
            backgroundOpacity: 1,
            mirrorHorizontal: settings.mirrorHorizontal,
            mirrorVertical: settings.mirrorVertical,
            linesAbove: 1.5
        )
    }

    /// Height of a view that shows exactly `visibleLines` lines (the camera band in portrait). Uses at least one line.
    public var preferredHeight: Double {
        PrompterRenderer.lineHeight(forFontSize: fontSize) * Double(max(visibleLines, 1)) + topInset + bottomInset
    }
}
