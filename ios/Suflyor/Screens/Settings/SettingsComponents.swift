import SuflyorDomain
import SwiftUI

/// Ranges of the settings (Android: constants of SettingsScreen.kt and OverlayController).
enum SettingLimits {
    static let minWpm = 60
    static let maxWpm = 260
    static let wpmStep = 10
    static let minFullScreenFont: Double = 18
    static let maxFullScreenFont: Double = 80
    static let minSideWidth = 28
    static let maxSideWidth = 100
    static let sideWidthStep = 4
}

/// A setting with a value and −/+ buttons (Android: `StepperRow`).
struct SettingStepper<Value: Strideable>: View {
    let title: String
    var hint: String?
    /// The value as text; the stepper's own accessibility value is replaced by it.
    let display: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(display)
    }
}

/// A switch with an explanation under it (Android: `ToggleRow`).
struct SettingToggle: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension SettingsStore {
    /// The action of one hardware key; nil = not assigned.
    func actionBinding(for key: HardwareKey) -> Binding<KeyAction?> {
        Binding(
            get: { MainActor.assumeIsolated { self.settings.keyBindings[key] } },
            set: { action in
                MainActor.assumeIsolated {
                    self.update { settings in
                        if let action {
                            settings.keyBindings[key] = action
                        } else {
                            settings.keyBindings.removeValue(forKey: key)
                        }
                    }
                }
            }
        )
    }
}

extension SettingsPage {
    var title: String {
        switch self {
        case .readiness: L10n.text("ios_app_settings_readiness")
        case .cameraText: L10n.text("ios_app_settings_camera_text")
        case .fullScreen: L10n.text("settings_section_fullscreen")
        case .voice: L10n.text("settings_section_voice")
        case .timed: L10n.text("settings_section_autoscroll")
        case .text: L10n.text("settings_section_text")
        case .keys: L10n.text("settings_section_keys")
        case .scripts: L10n.text("settings_section_scripts")
        case .advanced: L10n.text("settings_section_advanced")
        case .about: L10n.text("settings_section_about")
        }
    }
}

extension HardwareKey {
    var title: String { L10n.text("ios_app_key_\(rawValue)") }
}

extension KeyAction {
    /// Android string keys: key_action_pause, key_action_back, key_action_forward.
    var title: String { L10n.text("key_action_\(rawValue)") }
}
