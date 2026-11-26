import Foundation
import SuflyorDomain
import SuflyorPrompter
import SuflyorSpeech
import UIKit

// Starting and stopping the three ways to show the script. The app owns the microphone for rehearsal and the
// floating window; the camera screen brings its own capture session and audio source.

extension AppEnvironment {
    // MARK: - Camera

    func startCamera() async {
        guard let prepared = library.prepared else { return }
        guard await ensureCamera() else { return }
        // The screen follows the script the store holds: hand it over before presenting.
        session.setScript(prepared)
        router.showCamera = true
    }

    func closeCamera() {
        router.showCamera = false
        // The screen stops its own session; this makes sure nothing keeps listening.
        session.stop()
    }

    // MARK: - Rehearsal

    /// The screen starts the session itself with the microphone from `audioFactory` (see RootView).
    func startRehearsal() async {
        guard let prepared = library.prepared else { return }
        guard await ensureMicrophone() else { return }
        session.setScript(prepared)
        router.showRehearsal = true
    }

    func closeRehearsal() {
        router.showRehearsal = false
        session.stop()
    }

    // MARK: - Picture in Picture ("Over another app")

    func openPictureInPictureSheet() {
        guard PiPPrompter.isSupported, let prepared = library.prepared else { return }
        session.setScript(prepared)
        router.showPictureInPicture = true
    }

    /// The sheet's host view is on screen, so the system can start the window from it.
    func startPictureInPicture() async {
        guard library.prepared != nil, !pictureInPictureRunning else { return }
        guard await ensureMicrophone() else { return }
        session.start(mode: .pictureInPicture, audio: MicrophoneAudioSource())
        pip.start()
        pictureInPictureRunning = true
        Journal.shared.info("Picture in Picture started, target \(settings.settings.overlayTarget.rawValue)")
        let target = settings.settings.overlayTarget
        // VERIFY: OverlayTargetLauncher.open(_:) / hint(for:target:) signatures as announced by WP-D.
        let outcome = await OverlayTargetLauncher.open(target)
        if let hint = OverlayTargetLauncher.hint(for: outcome, target: target) {
            showToast(hint)
        }
    }

    func stopPictureInPicture() {
        guard pictureInPictureRunning else { return }
        pip.stop()
        session.stop()
        pictureInPictureRunning = false
        Journal.shared.info("Picture in Picture stopped")
    }
}

extension OverlayTarget {
    /// Android string keys: camera_target_camera and _window_only (the two brand names are not translated).
    var label: String {
        switch self {
        case .instagram: "Instagram" // a brand name: not translated
        case .tiktok: "TikTok"
        case .camera: L10n.text("camera_target_camera")
        case .none: L10n.text("camera_target_window_only")
        }
    }

    /// Installed on this phone (the system Camera and "window only" are always offered).
    @MainActor
    var isAvailable: Bool {
        let schemes: [String]
        switch self {
        case .instagram: schemes = ["instagram"]
        case .tiktok: schemes = ["snssdk1233", "tiktok"]
        case .camera, .none: return true
        }
        return schemes.contains { scheme in
            URL(string: "\(scheme)://").map { UIApplication.shared.canOpenURL($0) } ?? false
        }
    }
}
