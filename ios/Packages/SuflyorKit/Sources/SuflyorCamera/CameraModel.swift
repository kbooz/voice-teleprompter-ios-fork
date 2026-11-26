import AVFoundation
import Foundation
import Observation
import Photos
import SuflyorDomain
import SuflyorSession

/// State of one camera screen: permissions, the capture session, the recording and what to do with the file.
@MainActor
@Observable
final class CameraModel {
    enum Access {
        case unknown
        case granted
        case denied
    }

    struct Recording: Equatable {
        var url: URL
        var savedToPhotos: Bool
        /// Why the file did not reach Photos, if it did not.
        var note: String?
    }

    private(set) var access: Access = .unknown
    /// The capture session is running and the speech session is attached.
    private(set) var ready = false
    private(set) var isRecording = false
    private(set) var isFinishing = false
    private(set) var elapsed: TimeInterval = 0
    /// The phone is hot (thermal state serious or critical).
    private(set) var hot = false
    var errorMessage: String?
    var finished: Recording?

    @ObservationIgnored private var cachedRecorder: CameraRecorder?
    @ObservationIgnored private var cachedAudio: CaptureAudioSource?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// Created on first use: the preview needs the session before the screen has started anything.
    var recorder: CameraRecorder {
        if let cachedRecorder { return cachedRecorder }
        let created = CameraRecorder { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        cachedRecorder = created
        return created
    }

    private var audioSource: CaptureAudioSource {
        if let cachedAudio { return cachedAudio }
        let created = CaptureAudioSource(recorder: recorder)
        cachedAudio = created
        return created
    }

    // MARK: Lifecycle

    /// Asks for permission, starts the capture session and then the speech session on the same microphone.
    func start(store: SessionStore, settings: PrompterSettings) async {
        guard !started else { return }
        started = true
        if !CameraPermission.isGranted {
            guard await CameraPermission.request() else {
                access = .denied
                return
            }
        }
        access = .granted
        do {
            try await recorder.prepare(frameRate: settings.recordFrameRate)
        } catch {
            Journal.shared.error("Camera: couldn't start", error)
            errorMessage = error.localizedDescription
            return
        }
        recorder.refreshAngles()
        ready = true
        store.start(mode: .camera, audio: audioSource)
    }

    /// Leaves the screen: a recording in progress is finished and saved rather than lost.
    func shutdown() async {
        await finishRecordingIfNeeded()
        cachedAudio?.stop()
        cachedRecorder?.shutdown()
        ready = false
        started = false
    }

    // MARK: Recording

    func toggleRecording(settings: PrompterSettings) async {
        if isRecording {
            await finishRecordingIfNeeded()
        } else {
            startRecording(settings: settings)
        }
    }

    private func startRecording(settings: PrompterSettings) {
        guard ready, !isRecording, !isFinishing else { return }
        finished = nil
        errorMessage = nil
        do {
            _ = try recorder.startRecording(hevc: settings.recordHEVC)
        } catch {
            Journal.shared.error("Camera: couldn't start recording", error)
            errorMessage = error.localizedDescription
            return
        }
        isRecording = true
        elapsed = 0
        startedAt = Date()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    /// Stops, then saves to Photos. Does nothing when not recording.
    func finishRecordingIfNeeded() async {
        guard isRecording, !isFinishing else { return }
        isFinishing = true
        timerTask?.cancel()
        timerTask = nil
        defer {
            isRecording = false
            isFinishing = false
        }
        do {
            let url = try await recorder.stopRecording()
            var recording = Recording(url: url, savedToPhotos: false, note: nil)
            let outcome = await Self.saveToPhotos(url)
            recording.savedToPhotos = outcome.saved
            recording.note = outcome.note
            finished = recording
        } catch {
            Journal.shared.error("Camera: recording failed", error)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Photos

    /// Add-only access: the app can put the video in the library but cannot read it.
    private static func saveToPhotos(_ url: URL) async -> (saved: Bool, note: String?) {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return (false, L10n.text("ios_camera_photos_denied"))
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return (true, nil)
        } catch {
            Journal.shared.error("Camera: saving to Photos", error)
            return (false, L10n.text("ios_camera_photos_failed", error.localizedDescription))
        }
    }

    // MARK: Events

    private func handle(_ event: CameraRecorder.Event) {
        switch event {
        case .thermal(let state):
            hot = state == .serious || state == .critical
        case .interrupted:
            break
        case .writerFailed(let detail):
            errorMessage = L10n.text("ios_camera_failed", detail)
        }
    }

    // MARK: Formatting

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
