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
        guard library.prepared != nil else { return }
        guard await ensureCamera() else { return }
        router.showCamera = true
    }

    func closeCamera() {
        router.showCamera = false
        // The screen stops its own session; this makes sure nothing keeps listening.
        session.stop()
    }

    // MARK: - Rehearsal

    func startRehearsal() async {
        guard library.prepared != nil else { return }
        guard await ensureMicrophone() else { return }
        session.start(mode: .rehearsal, audio: MicrophoneAudioSource())
        router.showRehearsal = true
    }

    func closeRehearsal() {
        router.showRehearsal = false
        session.stop()
    }

    // MARK: - Picture in Picture ("Over another app")

    func openPictureInPictureSheet() {
        guard PiPPrompter.isSupported, library.prepared != nil else { return }
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
        await openTargetApp()
    }

    func stopPictureInPicture() {
        guard pictureInPictureRunning else { return }
        pip.stop()
        session.stop()
        pictureInPictureRunning = false
        Journal.shared.info("Picture in Picture stopped")
    }

    /// The app the floating window goes over. The URL schemes are not public API of those apps: VERIFY on a device.
    private func openTargetApp() async {
        let target = settings.settings.overlayTarget
        let candidates: [String]
        switch target {
        case .instagram: candidates = ["instagram://camera", "instagram://app"] // VERIFY: scheme still opens the camera
        case .tiktok: candidates = ["snssdk1233://", "tiktok://"] // VERIFY: scheme of the current TikTok
        case .camera:
            // The system Camera has no URL scheme: the user opens it.
            showToast(L10n.text("ios_app_open_camera_yourself"))
            return
        case .none:
            return
        }
        for text in candidates {
            guard let url = URL(string: text), UIApplication.shared.canOpenURL(url) else { continue }
            if await UIApplication.shared.open(url) { return }
        }
        showToast(L10n.text("main_open_app_failed", target.label))
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
