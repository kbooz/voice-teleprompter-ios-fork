import AVFoundation
import CoreMedia
import Foundation
import SuflyorDomain
import Synchronization

enum CameraError: Error, LocalizedError {
    case noCamera
    case noMicrophone
    case cannotAddDevice
    case audioSession(String)
    case notRecording
    case noFrames
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: L10n.text("ios_camera_error_no_camera")
        case .noMicrophone: L10n.text("ios_camera_error_no_microphone")
        case .cannotAddDevice: L10n.text("ios_camera_error_session")
        case .audioSession(let detail): L10n.text("ios_prompter_error_session_activation", detail)
        case .notRecording: L10n.text("ios_camera_error_not_recording")
        case .noFrames: L10n.text("ios_camera_error_no_frames")
        case .writer(let detail): L10n.text("ios_camera_failed", detail)
        }
    }
}

/// One `AVCaptureSession` with the front camera and the microphone, feeding two things from the same buffers: an
/// `AVAssetWriter` (the movie file) and, through `setAudioHandler`, the speech recognizer. One microphone client, so
/// the session follows exactly the audio that is recorded.
///
/// Threading, because nothing here can be compiled and checked: the class is `@unchecked Sendable` on these rules.
/// - `sessionQueue` owns session configuration, `startRunning` and the device.
/// - `sampleQueue` (serial) receives every video and audio buffer and owns all writer state; writer calls from
///   outside go through `sampleQueue.sync` / `.async`.
/// - `previewLayer`, `rotationCoordinator` and `observations` are touched on the main actor only.
/// - Shared values that two queues touch sit behind a `Mutex`.
final class CameraRecorder: NSObject, @unchecked Sendable {
    enum Event: Sendable {
        case thermal(ProcessInfo.ThermalState)
        case interrupted(Bool)
        case writerFailed(String)
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.suflyor.camera.session")
    private let sampleQueue = DispatchQueue(label: "app.suflyor.camera.samples")
    private let onEvent: @Sendable (Event) -> Void

    // sessionQueue
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDevice: AVCaptureDevice?
    private var configured = false

    // sampleQueue
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var finishingWriter: AVAssetWriter?
    private var outputURL: URL?
    private var sessionStarted = false
    private var droppedVideoFrames = 0

    // Shared
    private let audioHandler = Mutex<(@Sendable (CMSampleBuffer) -> Void)?>(nil)
    private let interruptionHandler = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    /// Degrees the picture must turn to be upright, from `AVCaptureDevice.RotationCoordinator`.
    private let captureAngle = Mutex<Double>(90)

    // Main actor
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.thermalStateChanged()
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            // VERIFY: the reason key is `AVCaptureSessionInterruptionReasonKey`; logged as a raw number for the journal.
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            Journal.shared.warning("Camera session interrupted, reason \(reason)")
            self?.notifyInterruption(true)
            self?.onEvent(.interrupted(true))
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            Journal.shared.info("Camera session interruption ended")
            self?.notifyInterruption(false)
            self?.onEvent(.interrupted(false))
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Journal.shared.error("Camera runtime error: \(error?.localizedDescription ?? "unknown")")
        })
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: Hooks for the audio source

    func setAudioHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        audioHandler.withLock { $0 = handler }
    }

    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        interruptionHandler.withLock { $0 = handler }
    }

    private func currentAudioHandler() -> (@Sendable (CMSampleBuffer) -> Void)? {
        audioHandler.withLock { $0 }
    }

    private func notifyInterruption(_ began: Bool) {
        let handler = interruptionHandler.withLock { $0 }
        handler?(began)
    }

    // MARK: Session

    /// Sets up the audio session and the capture session and starts it. Safe to call again (settings changes).
    func prepare(frameRate: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async {
                do {
                    try self.configureAndStart(frameRate: frameRate)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            // Lets other apps' audio come back and clears the orange microphone dot.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func configureAndStart(frameRate: Int) throws {
        if !configured {
            // The app owns the audio session (the speech side of the app relies on it): the capture session must not
            // reconfigure it behind our back.
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .videoRecording,
                    options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
                )
                try audioSession.setActive(true)
            } catch {
                throw CameraError.audioSession(error.localizedDescription)
            }

            session.beginConfiguration()
            session.automaticallyConfiguresApplicationAudioSession = false
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                session.commitConfiguration()
                throw CameraError.noCamera
            }
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                session.commitConfiguration()
                throw CameraError.noMicrophone
            }
            do {
                let cameraInput = try AVCaptureDeviceInput(device: camera)
                let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput) else {
                    session.commitConfiguration()
                    throw CameraError.cannotAddDevice
                }
                session.addInput(cameraInput)
                session.addInput(microphoneInput)
            } catch let error as CameraError {
                throw error
            } catch {
                session.commitConfiguration()
                throw CameraError.writer(error.localizedDescription)
            }

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
                session.commitConfiguration()
                throw CameraError.cannotAddDevice
            }
            session.addOutput(videoOutput)
            session.addOutput(audioOutput)

            // The file shows the true picture, not the mirror the preview shows (the preview layer mirrors by itself).
            if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            videoDevice = camera
            configured = true
        }
        applyFrameRate(frameRate)
        if !session.isRunning { session.startRunning() }
    }

    /// 30 or 60 fps if the active (or a 1080p) format allows it, else 30.
    private func applyFrameRate(_ requested: Int) {
        guard let device = videoDevice else { return }
        var fps = max(1, requested)
        func supports(_ format: AVCaptureDevice.Format) -> Bool {
            format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
            }
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if !supports(device.activeFormat) {
                // VERIFY: front camera formats at 1080p that reach 60 fps; changing the format drops the preset.
                let candidate = device.formats.first { format in
                    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return size.width == 1920 && size.height == 1080 && supports(format)
                }
                if let candidate {
                    session.beginConfiguration()
                    device.activeFormat = candidate
                    session.commitConfiguration()
                } else {
                    Journal.shared.warning("Camera: \(fps) fps not available, recording at 30")
                    fps = 30
                }
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            Journal.shared.error("Camera: couldn't set the frame rate", error)
        }
    }

    // MARK: Rotation (main actor)

    /// Connects the preview and keeps its rotation, and the recording's, upright as the phone turns.
    @MainActor
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        guard
            rotationCoordinator == nil,
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: layer)
        rotationCoordinator = coordinator
        observations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshAngles() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshAngles() }
            },
        ]
        refreshAngles()
    }

    /// Also to call once the session has its connections (after `prepare`).
    @MainActor
    func refreshAngles() {
        guard let coordinator = rotationCoordinator else { return }
        captureAngle.withLock { $0 = Double(coordinator.videoRotationAngleForHorizonLevelCapture) }
        if let connection = previewLayer?.connection {
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    // MARK: Recording

    /// Starts a new movie file. The writer starts its timeline at the first video frame; audio before it is dropped.
    func startRecording(hevc: Bool) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Suflyor-\(stamp).mov")
        try? FileManager.default.removeItem(at: url)
        let angle = captureAngle.withLock { $0 }
        try sampleQueue.sync { try self.beginWriter(url: url, hevc: hevc, angle: angle) }
        return url
    }

    private func beginWriter(url: URL, hevc: Bool, angle: Double) throws {
        guard self.writer == nil else { return }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let codec: AVVideoCodecType = hevc ? .hevc : .h264
        // The output's own recommendation matches the sensor format (size, bit rate, profile).
        let videoSettings: [String: Any] = videoOutput.recommendedVideoSettings(
            forVideoCodecType: codec,
            assetWriterOutputFileType: .mov
        ) ?? [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        // Buffers arrive in sensor orientation; the file turns them upright with this transform.
        video.transform = CGAffineTransform(rotationAngle: CGFloat(angle * .pi / 180))

        // VERIFY: the recommended audio settings come back as [AnyHashable: Any]; AAC at the microphone's rate.
        let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(audio) else { throw CameraError.writer("inputs") }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            throw CameraError.writer(writer.error?.localizedDescription ?? "startWriting")
        }
        self.writer = writer
        videoInput = video
        audioInput = audio
        outputURL = url
        sessionStarted = false
        droppedVideoFrames = 0
        Journal.shared.info("Recording started: \(hevc ? "HEVC" : "H.264"), angle \(Int(angle))")
    }

    /// Finishes the file and returns it. Throws when nothing was recorded.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            sampleQueue.async {
                guard let writer = self.writer, let url = self.outputURL else {
                    continuation.resume(throwing: CameraError.notRecording)
                    return
                }
                let started = self.sessionStarted
                let dropped = self.droppedVideoFrames
                self.writer = nil
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.videoInput = nil
                self.audioInput = nil
                self.outputURL = nil
                guard started else {
                    writer.cancelWriting()
                    continuation.resume(throwing: CameraError.noFrames)
                    return
                }
                // Held here so the completion handler reads it through `self` on the queue, not as a capture.
                self.finishingWriter = writer
                writer.finishWriting {
                    self.sampleQueue.async {
                        let finished = self.finishingWriter
                        self.finishingWriter = nil
                        if finished?.status == .completed {
                            Journal.shared.info("Recording saved, \(dropped) video frames dropped")
                            continuation.resume(returning: url)
                        } else {
                            let detail = finished?.error?.localizedDescription ?? "unknown"
                            Journal.shared.error("Recording failed: \(detail)")
                            continuation.resume(throwing: CameraError.writer(detail))
                        }
                    }
                }
            }
        }
    }

    // MARK: Samples (sampleQueue)

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard
            let writer, writer.status == .writing, let videoInput,
            CMSampleBufferDataIsReady(sampleBuffer)
        else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else {
            droppedVideoFrames += 1
            return
        }
        if !videoInput.append(sampleBuffer) { failWriter(writer) }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard
            sessionStarted, let writer, writer.status == .writing, let audioInput,
            CMSampleBufferDataIsReady(sampleBuffer), audioInput.isReadyForMoreMediaData
        else { return }
        if !audioInput.append(sampleBuffer) { failWriter(writer) }
    }

    private func failWriter(_ failed: AVAssetWriter) {
        let detail = failed.error?.localizedDescription ?? "append failed"
        Journal.shared.error("Recording writer failed: \(detail)")
        onEvent(.writerFailed(detail))
    }

    private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .serious: Journal.shared.warning("Thermal state: serious, the phone is hot")
        case .critical: Journal.shared.warning("Thermal state: critical, recording may be stopped by the system")
        case .nominal, .fair: Journal.shared.info("Thermal state: \(state == .fair ? "fair" : "nominal")")
        @unknown default: Journal.shared.info("Thermal state changed")
        }
        onEvent(.thermal(state))
    }
}

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // One method serves both protocols: they share the signature, and `output` says which stream it is.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            // Speech first: following the voice matters more than the file, and the handler only converts and yields.
            currentAudioHandler()?(sampleBuffer)
            appendAudio(sampleBuffer)
        } else if output === videoOutput {
            appendVideo(sampleBuffer)
        }
    }
}
