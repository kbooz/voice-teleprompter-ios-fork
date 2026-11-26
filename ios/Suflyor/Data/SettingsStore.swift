import Foundation
import Observation
import SuflyorDomain
import SwiftUI

/// The user's `PrompterSettings`, stored as JSON in `UserDefaults` (Android: `App.Settings`).
@MainActor @Observable
final class SettingsStore {
    private static let key = "suflyor.prompterSettings.v1"

    /// Change only through `update(_:)` / `apply(_:)` so it is saved and passed on.
    private(set) var settings: PrompterSettings

    /// Called after every change with the old and new values: the app pushes them to the session and re-lays out.
    @ObservationIgnored var onChange: (@MainActor (_ old: PrompterSettings, _ new: PrompterSettings) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            // Keys added by a newer version of the app keep their defaults.
            settings = PrompterSettings.decodeMergingDefaults(data)
        } else {
            settings = PrompterSettings()
        }
    }

    func update(_ change: (inout PrompterSettings) -> Void) {
        var copy = settings
        change(&copy)
        apply(copy)
    }

    func apply(_ new: PrompterSettings) {
        guard new != settings else { return }
        let old = settings
        settings = new
        if let data = try? JSONEncoder().encode(new) {
            defaults.set(data, forKey: Self.key)
        }
        onChange?(old, new)
    }

    /// Back to the defaults (the key bindings page has its own reset).
    func resetKeyBindings() {
        update { $0.keyBindings = KeyBindings.default }
    }

    /// A binding to one field. `MainActor.assumeIsolated`: SwiftUI reads and writes bindings on the main thread, but
    /// the closures may be declared `@Sendable` by the SDK.
    // VERIFY: `WritableKeyPath & Sendable` accepts key path literals (`\.fontSize`) at every call site.
    func binding<Value: Sendable>(_ keyPath: WritableKeyPath<PrompterSettings, Value> & Sendable) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { self.settings[keyPath: keyPath] } },
            set: { value in MainActor.assumeIsolated { self.update { $0[keyPath: keyPath] = value } } }
        )
    }

    /// The whole value, for `CameraScreen`, `RehearsalScreen` and `TuneSheet`.
    var wholeBinding: Binding<PrompterSettings> {
        Binding(
            get: { MainActor.assumeIsolated { self.settings } },
            set: { value in MainActor.assumeIsolated { self.apply(value) } }
        )
    }

    /// The mirror setting of the full-screen prompter as one choice (Android: `MirrorMode`).
    var mirrorBinding: Binding<MirrorMode> {
        Binding(
            get: { MainActor.assumeIsolated { MirrorMode.of(self.settings) } },
            set: { mode in
                MainActor.assumeIsolated {
                    self.update {
                        $0.mirrorHorizontal = mode.horizontal
                        $0.mirrorVertical = mode.vertical
                    }
                }
            }
        )
    }
}

/// How the full-screen prompter is flipped for teleprompter glass; rigs differ, so both axes can be chosen.
enum MirrorMode: String, CaseIterable, Identifiable, Sendable {
    case off, horizontal, vertical, both

    var id: String { rawValue }
    var horizontal: Bool { self == .horizontal || self == .both }
    var vertical: Bool { self == .vertical || self == .both }

    /// Android string keys: mirror_off, mirror_horizontal, mirror_vertical, mirror_both.
    var label: String { L10n.text("mirror_\(rawValue)") }

    static func of(_ settings: PrompterSettings) -> MirrorMode {
        switch (settings.mirrorHorizontal, settings.mirrorVertical) {
        case (false, false): .off
        case (true, false): .horizontal
        case (false, true): .vertical
        case (true, true): .both
        }
    }
}
