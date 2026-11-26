import SuflyorDomain
import UIKit

/// Opens the app the Picture in Picture window should float over (Android: `CameraTarget.launchIntent`).
///
/// iOS has no public URL scheme for the stock Camera app, and the schemes of Instagram and TikTok are not documented
/// APIs: they can change in any release of those apps. The caller must have the schemes in `LSApplicationQueriesSchemes`
/// (`instagram`, `snssdk1233`, `tiktok`) for `canOpenURL` to answer.
public enum OverlayTargetLauncher {
    public enum Outcome: Hashable, Sendable {
        case opened
        /// The app isn't installed (or its scheme isn't whitelisted in Info.plist).
        case notInstalled
        /// No way to open it from here: tell the user to open it themselves (stock Camera).
        case openManually
        /// `OverlayTarget.none`: the window alone.
        case nothingToOpen
    }

    /// Candidate URLs in order of preference.
    static func urls(for target: OverlayTarget) -> [String] {
        switch target {
        // VERIFY: "instagram://camera" opens the in-app camera; plain "instagram://app" opens the app.
        case .instagram: ["instagram://camera", "instagram://app"]
        // VERIFY: TikTok's scheme is "snssdk1233://" (global build), "tiktok://" on some versions; neither is documented.
        case .tiktok: ["snssdk1233://", "tiktok://"]
        case .camera, .none: []
        }
    }

    @MainActor
    public static func open(_ target: OverlayTarget) async -> Outcome {
        switch target {
        case .none: return .nothingToOpen
        case .camera: return .openManually
        case .instagram, .tiktok:
            for string in urls(for: target) {
                guard let url = URL(string: string), UIApplication.shared.canOpenURL(url) else { continue }
                if await UIApplication.shared.open(url) { return .opened }
            }
            return .notInstalled
        }
    }

    /// Text for the screen that explains what to do next.
    public static func hint(for outcome: Outcome, target: OverlayTarget) -> String? {
        switch outcome {
        case .opened, .nothingToOpen: nil
        case .openManually: L10n.text("ios_prompter_open_manually_camera")
        case .notInstalled: L10n.text("ios_prompter_target_not_installed", targetName(target))
        }
    }

    private static func targetName(_ target: OverlayTarget) -> String {
        switch target {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .camera: L10n.text("camera_target_camera")
        case .none: L10n.text("camera_target_window_only")
        }
    }
}
