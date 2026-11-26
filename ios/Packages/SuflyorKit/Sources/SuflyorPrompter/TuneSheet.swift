import SuflyorDomain
import SwiftUI

/// The "Aa" sheet: text size, lines (or band width sideways), background, speed and margins, and over the full screen
/// also the mirror. Android's `OverlayController.buildTuneRow` and the rehearsal "View" sheet in one.
///
/// Changes write straight into `settings`, so the text behind the sheet follows while you press the buttons.
public struct TuneSheet: View {
    @Binding private var settings: PrompterSettings
    private let fullScreen: Bool
    /// Sideways on iPhone the band fills the height: "Lines" means nothing there, "Width" takes its place.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(settings: Binding<PrompterSettings>, fullScreen: Bool) {
        _settings = settings
        self.fullScreen = fullScreen
    }

    private enum MirrorChoice: Int, CaseIterable {
        case off, horizontal, vertical, both

        var label: String {
            switch self {
            case .off: L10n.text("mirror_off")
            case .horizontal: L10n.text("mirror_horizontal")
            case .vertical: L10n.text("mirror_vertical")
            case .both: L10n.text("mirror_both")
            }
        }

        init(horizontal: Bool, vertical: Bool) {
            switch (horizontal, vertical) {
            case (false, false): self = .off
            case (true, false): self = .horizontal
            case (false, true): self = .vertical
            case (true, true): self = .both
            }
        }

        var flags: (horizontal: Bool, vertical: Bool) {
            (self == .horizontal || self == .both, self == .vertical || self == .both)
        }
    }

    public var body: some View {
        let sideways = verticalSizeClass == .compact
        ScrollView {
            VStack(spacing: 4) {
                if fullScreen {
                    StepRow(
                        title: L10n.text("settings_font_title"),
                        value: "\(Int(settings.fullScreenFontSize))",
                        canDecrease: settings.fullScreenFontSize > Self.fullScreenFontRange.lowerBound,
                        canIncrease: settings.fullScreenFontSize < Self.fullScreenFontRange.upperBound,
                        onMinus: { settings.fullScreenFontSize = Self.step(settings.fullScreenFontSize, -2, Self.fullScreenFontRange) },
                        onPlus: { settings.fullScreenFontSize = Self.step(settings.fullScreenFontSize, 2, Self.fullScreenFontRange) }
                    )
                    marginRows(
                        start: $settings.fullScreenPaddingStart,
                        end: $settings.fullScreenPaddingEnd
                    )
                } else {
                    StepRow(
                        title: L10n.text("overlay_tune_font"),
                        value: "\(Int(settings.fontSize))",
                        canDecrease: settings.fontSize > Self.overlayFontRange.lowerBound,
                        canIncrease: settings.fontSize < Self.overlayFontRange.upperBound,
                        onMinus: { settings.fontSize = Self.step(settings.fontSize, -2, Self.overlayFontRange) },
                        onPlus: { settings.fontSize = Self.step(settings.fontSize, 2, Self.overlayFontRange) }
                    )
                    if sideways {
                        StepRow(
                            title: L10n.text("overlay_tune_width"),
                            value: "\(settings.sideWidthPercent)%",
                            canDecrease: settings.sideWidthPercent > Self.sideWidthRange.lowerBound,
                            canIncrease: settings.sideWidthPercent < Self.sideWidthRange.upperBound,
                            onMinus: { settings.sideWidthPercent = Self.step(settings.sideWidthPercent, -6, Self.sideWidthRange) },
                            onPlus: { settings.sideWidthPercent = Self.step(settings.sideWidthPercent, 6, Self.sideWidthRange) }
                        )
                    } else {
                        StepRow(
                            title: L10n.text("overlay_tune_lines"),
                            value: "\(settings.visibleLines)",
                            canDecrease: settings.visibleLines > Self.linesRange.lowerBound,
                            canIncrease: settings.visibleLines < Self.linesRange.upperBound,
                            onMinus: { settings.visibleLines = Self.step(settings.visibleLines, -1, Self.linesRange) },
                            onPlus: { settings.visibleLines = Self.step(settings.visibleLines, 1, Self.linesRange) }
                        )
                    }
                    StepRow(
                        title: L10n.text("overlay_tune_background"),
                        value: "\(settings.backgroundOpacity)%",
                        canDecrease: settings.backgroundOpacity > Self.opacityRange.lowerBound,
                        canIncrease: settings.backgroundOpacity < Self.opacityRange.upperBound,
                        onMinus: { settings.backgroundOpacity = Self.step(settings.backgroundOpacity, -8, Self.opacityRange) },
                        onPlus: { settings.backgroundOpacity = Self.step(settings.backgroundOpacity, 8, Self.opacityRange) }
                    )
                    marginRows(start: $settings.paddingStart, end: $settings.paddingEnd)
                }
                StepRow(
                    title: L10n.text("overlay_tune_speed"),
                    value: L10n.text("speed_value", settings.autoScrollWpm),
                    canDecrease: settings.autoScrollWpm > Self.speedRange.lowerBound,
                    canIncrease: settings.autoScrollWpm < Self.speedRange.upperBound,
                    onMinus: { settings.autoScrollWpm = Self.step(settings.autoScrollWpm, -10, Self.speedRange) },
                    onPlus: { settings.autoScrollWpm = Self.step(settings.autoScrollWpm, 10, Self.speedRange) }
                )
                Toggle(L10n.text("settings_highlight_title"), isOn: $settings.wordHighlight)
                    .tint(PrompterPalette.accent)
                    .padding(.vertical, 6)
                if fullScreen { mirrorPicker }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(fullScreen ? [.medium, .large] : [.height(sideways ? 220 : 360), .large])
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
    }

    private func marginRows(start: Binding<Double>, end: Binding<Double>) -> some View {
        Group {
            StepRow(
                title: L10n.text("overlay_tune_margin_start"),
                value: "\(Int(start.wrappedValue))",
                canDecrease: start.wrappedValue > Self.marginRange.lowerBound,
                canIncrease: start.wrappedValue < Self.marginRange.upperBound,
                onMinus: { start.wrappedValue = Self.step(start.wrappedValue, -4, Self.marginRange) },
                onPlus: { start.wrappedValue = Self.step(start.wrappedValue, 4, Self.marginRange) }
            )
            StepRow(
                title: L10n.text("overlay_tune_margin_end"),
                value: "\(Int(end.wrappedValue))",
                canDecrease: end.wrappedValue > Self.marginRange.lowerBound,
                canIncrease: end.wrappedValue < Self.marginRange.upperBound,
                onMinus: { end.wrappedValue = Self.step(end.wrappedValue, -4, Self.marginRange) },
                onPlus: { end.wrappedValue = Self.step(end.wrappedValue, 4, Self.marginRange) }
            )
        }
    }

    private var mirrorPicker: some View {
        let selection = Binding<MirrorChoice>(
            get: { MirrorChoice(horizontal: settings.mirrorHorizontal, vertical: settings.mirrorVertical) },
            set: {
                settings.mirrorHorizontal = $0.flags.horizontal
                settings.mirrorVertical = $0.flags.vertical
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("settings_mirror_title")).font(.body)
            Text(L10n.text("settings_mirror_pick_hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker(L10n.text("settings_mirror_title"), selection: selection) {
                ForEach(MirrorChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // Android's limits: the text over the camera tops out at 48 (bigger would cover the face), the full screen at 80.
    private static let overlayFontRange: ClosedRange<Double> = 14...48
    private static let fullScreenFontRange: ClosedRange<Double> = 18...80
    private static let linesRange: ClosedRange<Int> = 1...8
    private static let sideWidthRange: ClosedRange<Int> = 28...100
    private static let opacityRange: ClosedRange<Int> = 24...96
    private static let speedRange: ClosedRange<Int> = 60...260
    private static let marginRange: ClosedRange<Double> = 0...200

    private static func step<T: Comparable & Numeric>(_ value: T, _ delta: T, _ range: ClosedRange<T>) -> T {
        min(max(value + delta, range.lowerBound), range.upperBound)
    }
}

/// Caption, minus, the current value, plus (Android's `tuneGroup`).
private struct StepRow: View {
    let title: String
    let value: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onMinus) { Image(systemName: "minus").frame(width: 40, height: 36) }
                .disabled(!canDecrease)
                .accessibilityLabel(L10n.text("stepper_cd_decrease", title))
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .frame(minWidth: 52)
            Button(action: onPlus) { Image(systemName: "plus").frame(width: 40, height: 36) }
                .disabled(!canIncrease)
                .accessibilityLabel(L10n.text("stepper_cd_increase", title))
        }
        .buttonStyle(.bordered)
        .tint(PrompterPalette.accent)
        .accessibilityElement(children: .contain)
    }
}
