import Foundation
import Synchronization

// MARK: - Settings

/// App where "Over another app" sends the user after the Picture in Picture window appears (Kotlin: `CameraTarget`).
public enum OverlayTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case instagram
    case tiktok
    case camera
    case none
}

/// User settings the modules read (Kotlin: `App.Settings`, same defaults). The app stores it as JSON in
/// `UserDefaults` (`SettingsStore`, WP-B) and hands a copy to the session and the prompter.
public struct PrompterSettings: Codable, Hashable, Sendable {
    // Script layout
    public var phraseMode = true
    public var maxWords = 7

    // Voice following
    /// "auto" picks the language from the script's letters, otherwise a `SpeechLanguage` code.
    public var speechLanguage = "auto"
    public var asrEngine: AsrEngineKind = .sherpa
    public var useHotwords = true
    /// Words the highlight runs ahead of the tracker while you speak, to hide recognition latency.
    public var leadWords = 1
    public var wordHighlight = false
    public var showDiagnostics = false

    // Timed scrolling
    public var autoScrollWpm = 130
    public var countdownSeconds = 3

    // Text over the camera / in Picture in Picture
    public var fontSize: Double = 26
    public var visibleLines = 3
    /// Opacity of the band behind the text, 0–100.
    public var backgroundOpacity = 72
    public var paddingStart: Double = 18
    public var paddingEnd: Double = 14
    /// Width of the band in landscape, percent of the screen width.
    public var sideWidthPercent = 46
    public var overlayTarget: OverlayTarget = .instagram

    // Full-screen rehearsal
    public var fullScreenFontSize: Double = 30
    public var fullScreenPaddingStart: Double = 20
    public var fullScreenPaddingEnd: Double = 16
    public var mirrorHorizontal = false
    public var mirrorVertical = false
    public var fullScreenControlsHidden = false

    // Remote keys
    public var keyControl = true
    public var keyBindings: [HardwareKey: KeyAction] = KeyBindings.default

    // Camera recording
    public var recordFrameRate = 30
    public var recordHEVC = false

    public init() {}

    /// Decodes settings saved by any version: keys missing from `data` (added later) keep their defaults, and data
    /// that can't be read at all gives the defaults.
    public static func decodeMergingDefaults(_ data: Data) -> PrompterSettings {
        guard
            let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let defaultsData = try? JSONEncoder().encode(PrompterSettings()),
            var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any]
        else { return PrompterSettings() }
        merged.merge(stored) { _, saved in saved }
        guard
            let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            let settings = try? JSONDecoder().decode(PrompterSettings.self, from: mergedData)
        else { return PrompterSettings() }
        return settings
    }

    /// The script's own language if it has one, else the setting, else detection by `core`.
    public func resolvedLanguage(
        for document: ImportedDocument,
        core: any ScriptCoreProviding
    ) -> SpeechLanguage {
        if let own = document.speechLanguage { return own }
        if let fixed = SpeechLanguage(code: speechLanguage) { return fixed }
        return core.detectLanguage(document.paragraphs)
    }
}

// MARK: - App-wide constants

public enum AppConstants {
    /// TODO(owner): replace with the real bundle identifier prefix before the first TestFlight build.
    public static let bundleIdPrefix = "com.example.suflyor"
    public static let appGroup = "group.com.example.suflyor"
    public static let logSubsystem = "com.example.suflyor"
    /// `suflyor://record?script=<id>`, `suflyor://pip?script=<id>`, `suflyor://import` (Share extension hand-off).
    public static let urlScheme = "suflyor"
    public static let speechPackReleaseBase = "https://github.com/olerast67/voice-teleprompter-android/releases/download/"
}

// MARK: - Localization

/// Looks up user-visible text in the app's String Catalog (`ios/Suflyor/Resources/Localizable.xcstrings`).
///
/// Keys are the Android resource names (`session_error_mic_busy`) or, for iOS-only text, `ios_<module>_<name>`.
/// Packages call this instead of `String(localized:)` so every key resolves against the app bundle.
public enum L10n {
    public static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    public static func text(_ key: String, _ args: any CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale.current, arguments: args)
    }
}

// MARK: - Diagnostics

/// The in-app journal (Kotlin: `diag.DiagLog`): a ring buffer the Journal screen shows and exports as text.
/// Never sent anywhere. Thread-safe.
public final class Journal: Sendable {
    public enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: UInt64
        public let date: Date
        public let level: Level
        public let message: String
    }

    public static let shared = Journal()

    private struct Storage {
        var nextId: UInt64 = 0
        var entries: [Entry] = []
    }

    private let capacity: Int
    private let storage = Mutex(Storage())

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func log(_ level: Level, _ message: String) {
        storage.withLock { s in
            s.entries.append(Entry(id: s.nextId, date: Date(), level: level, message: message))
            s.nextId += 1
            if s.entries.count > capacity { s.entries.removeFirst(s.entries.count - capacity) }
        }
    }

    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }

    public func error(_ message: String, _ error: (any Error)? = nil) {
        log(.error, error.map { "\(message): \($0)" } ?? message)
    }

    public func snapshot() -> [Entry] { storage.withLock { $0.entries } }

    public func clear() { storage.withLock { $0.entries.removeAll() } }

    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return snapshot()
            .map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}
