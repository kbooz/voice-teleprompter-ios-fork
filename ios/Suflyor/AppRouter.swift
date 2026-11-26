import Foundation
import Observation

/// One page of Settings (Android: `SettingsPage`).
enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
    case readiness, cameraText, fullScreen, voice, timed, text, keys, scripts, advanced, about

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .readiness: "checkmark.seal"
        case .cameraText: "video"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .voice: "mic"
        case .timed: "speedometer"
        case .text: "textformat"
        case .keys: "keyboard"
        case .scripts: "doc.text"
        case .advanced: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// Where the navigation stack can go. The library is the root and is not a route.
enum Route: Hashable {
    case script(String)
    /// nil = a new script.
    case editor(String?)
    case settings
    case settingsPage(SettingsPage)
    case journal
    case licenses
    case privacy
}

/// Navigation state shared by the screens, the deep links and the intents.
@MainActor @Observable
final class AppRouter {
    var path: [Route] = []
    var showCamera = false
    var showRehearsal = false
    var showPictureInPicture = false

    func pop() {
        if !path.isEmpty { path.removeLast() }
    }
}
