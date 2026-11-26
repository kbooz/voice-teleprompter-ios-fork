import Foundation
import SuflyorDomain

/// The hand-off between App Intents (Control Center, Action button, Shortcuts) and the app.
///
/// An intent may run in the extension process, and a process can't reliably open its host app, so the intent leaves
/// the requested `suflyor://` link in the App Group and asks the system to bring the app forward; the app reads the
/// link when it becomes active. When the intent runs inside the already running app, the notification does the same
/// without waiting for a scene change.
enum PendingRoute {
    private static let key = "pendingRoute"
    static let notification = Notification.Name("\(AppConstants.logSubsystem).route")

    static func leave(_ url: URL) {
        UserDefaults(suiteName: AppConstants.appGroup)?.set(url.absoluteString, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// Returns the waiting link once.
    static func take() -> URL? {
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroup),
              let text = defaults.string(forKey: key)
        else { return nil }
        defaults.removeObject(forKey: key)
        return URL(string: text)
    }
}
