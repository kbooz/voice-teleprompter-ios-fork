import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Observation
import SuflyorDomain
import SuflyorSession
import Synchronization
import SwiftUI
import UIKit

/// Draws the prompter into the Picture in Picture window, so it floats over Instagram, TikTok or the Camera app.
/// Experimental: the window belongs to the system (size, position and aspect are the user's), and iOS gives no way to
/// pin it under the lens. See plan section 4.3.
///
/// How it works: frames from `PrompterRenderer` (the same one the app screens use) go into pooled pixel buffers, then
/// sample buffers, then an `AVSampleBufferDisplayLayer` that `AVPictureInPictureController` floats. A frame is made
/// only when the state or the scroll position changes, never on a fixed clock, to save battery.
///
/// Requirements for the caller:
/// - The session must be running with `mode: .pictureInPicture` and a microphone source. The microphone's active
///   `AVAudioSession` (`.playAndRecord`) is what lets PiP start and keeps the app alive in the background
///   (`UIBackgroundModes` = `audio`). Without a running audio session `start()` falls back to a `.playback` session,
///   but then there is no voice following.
/// - `hostView` must be on screen before `start()`: PiP starts from a visible layer.
/// - If the session reports `interrupted` or `autoFallback` (another app took the microphone), the frame says it is
///   following by time (plan 4.4), and `AUTO` scrolling is up to the session.
@MainActor
@Observable
public final class PiPPrompter {
    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// The PiP window is showing.
    public private(set) var isActive = false
    /// Why the last `start()` failed, for the screen to show; nil otherwise.
    public private(set) var lastError: String?

    private let store: SessionStore
    private let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var bridge: PiPBridge?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var startWhenPossible = false

    @ObservationIgnored private var renderer: PrompterRenderer?
    @ObservationIgnored private var rendererHandle: CoreHandle?
    @ObservationIgnored private var scroll: Double = 0
    @ObservationIgnored private var target: Double = 0
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var pool: CVPixelBufferPool?
    @ObservationIgnored private var timebase: CMTimebase?

    /// Logical canvas in points and its pixel scale. 16:9, so the system window gets a wide, short shape: a few lines.
    private static let canvas = CGSize(width: 320, height: 180)
    private static let pixelScale: CGFloat = 2

    public init(store: SessionStore) {
        self.store = store
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        makeTimebase()
        if Self.isSupported { makeController() }
        observeStore()
    }

    /// The inline view PiP starts from; must be on screen before `start()`. It previews what the window will show.
    public var hostView: some View {
        PiPHostView(layer: displayLayer, onAttach: { [weak self] in self?.storeChanged() })
            .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
    }

    public func start() {
        lastError = nil
        guard Self.isSupported, let controller else {
            lastError = L10n.text("ios_prompter_pip_unsupported")
            return
        }
        prepareAudioSession()
        storeChanged()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // The layer needs a moment on screen with a frame in it before the system allows PiP.
            startWhenPossible = true
        }
    }

    public func stop() {
        startWhenPossible = false
        controller?.stopPictureInPictureIfActive()
        frameTask?.cancel()
        frameTask = nil
    }

    // MARK: Setup

    private func makeController() {
        let bridge = PiPBridge()
        bridge.owner = self
        self.bridge = bridge
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: bridge
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = bridge
        // Leaving the app for Instagram or the Camera opens the window by itself, without a button press.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.possibleChanged() }
        }
    }

    private func makeTimebase() {
        var created: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &created
        )
        guard status == noErr, let created else { return }
        CMTimebaseSetTime(created, time: .zero)
        CMTimebaseSetRate(created, rate: 1)
        timebase = created
        displayLayer.controlTimebase = created
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord, session.category != .playback else { return }
        // VERIFY(device): PiP needs an active session in one of these categories. With the microphone running (.playAndRecord) this
        // is skipped; mixing keeps the user's music playing.
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Journal.shared.error("PiP: audio session", error)
        }
    }

    private func possibleChanged() {
        guard startWhenPossible, let controller, controller.isPictureInPicturePossible else { return }
        startWhenPossible = false
        controller.startPictureInPicture()
    }

    // MARK: Following the session

    private func observeStore() {
        withObservationTracking {
            _ = store.state
            _ = store.script
            _ = store.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.storeChanged()
                self?.observeStore()
            }
        }
    }

    private var style: PrompterStyle {
        var style = PrompterStyle.overCamera(store.settings)
        // The window is a video: opaque, and a read line above the reading line for context.
        style.backgroundOpacity = 1
        style.linesAbove = 0.8
        return style
    }

    private func storeChanged() {
        let state = store.state
        if let script = store.script {
            if rendererHandle !== script.handle || renderer == nil {
                renderer = PrompterRenderer(script: script)
                rendererHandle = script.handle
                scroll = 0
            }
            bridge?.update(paused: state.paused, durationSeconds: Double(max(60, script.durationSeconds(wpm: store.settings.autoScrollWpm))))
        } else {
            renderer = nil
            rendererHandle = nil
        }
        if let timebase { CMTimebaseSetRate(timebase, rate: state.paused ? 0 : 1) }
        retarget()
        if scroll != target { ensureAnimating() } else { renderFrame() }
        controller?.invalidatePlaybackState()
    }

    private func retarget() {
        guard let renderer else { return }
        let style = style
        renderer.configure(style: style, size: Self.canvas)
        target = renderer.targetOffset(nextToken: store.state.nextToken, linesAbove: style.linesAbove)
    }

    // MARK: Frames

    private func ensureAnimating() {
        guard frameTask == nil else { return }
        // A task, not CADisplayLink: display links stop while the app is in the background, which is exactly when
        // the PiP window is the only thing on screen.
        frameTask = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self else { return }
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let dtMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                if !self.advance(dtMs: dtMs) {
                    self.frameTask = nil
                    return
                }
            }
        }
    }

    /// One animation step; false once the text has settled on its target.
    private func advance(dtMs: Double) -> Bool {
        scroll = PrompterLayoutMath.smoothed(current: scroll, target: target, dtMs: dtMs)
        renderFrame()
        return scroll != target
    }

    private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        var created: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        return created
    }

    func renderFrame() {
        let width = Int(Self.canvas.width * Self.pixelScale)
        let height = Int(Self.canvas.height * Self.pixelScale)
        if pool == nil { pool = makePool(width: width, height: height) }
        guard let pool else { return }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn = draw(into: buffer, width: width, height: height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn else { return }
        enqueue(buffer)
    }

    private func draw(into buffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard
            let base = CVPixelBufferGetBaseAddress(buffer),
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return false }
        // Bitmap contexts are y-up: flip to the top-left origin the renderer expects, and work in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: Self.pixelScale, y: -Self.pixelScale)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: Self.canvas))

        let state = store.state
        if let renderer {
            renderer.draw(in: context, size: Self.canvas, scrollOffset: scroll, nextToken: state.nextToken, style: style)
        }
        if state.countdown > 0 {
            drawCenteredText("\(state.countdown)", in: context, size: 72, color: UIColor(red: 1, green: 176 / 255, blue: 32 / 255, alpha: 1))
        }
        if state.interrupted || state.autoFallback || state.micFailed {
            drawNotice(in: context)
        }
        return true
    }

    /// "Following by time": the microphone was taken (plan 4.4), the text now scrolls on its own.
    private func drawNotice(in context: CGContext) {
        let title = L10n.text("ios_prompter_pip_following_by_time")
        let hint = L10n.text("ios_prompter_pip_hint_record_in_app")
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor(white: 1, alpha: 0.75),
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let hintSize = (hint as NSString).size(withAttributes: hintAttributes)
        let width = min(Self.canvas.width - 12, max(titleSize.width, hintSize.width) + 16)
        let height = titleSize.height + hintSize.height + 10
        let rect = CGRect(x: (Self.canvas.width - width) / 2, y: Self.canvas.height - height - 6, width: width, height: height)
        UIGraphicsPushContext(context)
        UIColor(red: 0.55, green: 0.1, blue: 0.1, alpha: 0.92).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()
        (title as NSString).draw(
            in: CGRect(x: rect.minX + 8, y: rect.minY + 4, width: width - 16, height: titleSize.height),
            withAttributes: titleAttributes
        )
        (hint as NSString).draw(
            in: CGRect(x: rect.minX + 8, y: rect.minY + 4 + titleSize.height + 2, width: width - 16, height: hintSize.height),
            withAttributes: hintAttributes
        )
        UIGraphicsPopContext()
    }

    private func drawCenteredText(_ text: String, in context: CGContext, size: CGFloat, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        UIGraphicsPushContext(context)
        (text as NSString).draw(
            at: CGPoint(x: (Self.canvas.width - measured.width) / 2, y: (Self.canvas.height - measured.height) / 2),
            withAttributes: attributes
        )
        UIGraphicsPopContext()
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
            let format
        else { return }
        let time = timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil,
                imageBuffer: buffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sample
            ) == noErr,
            let sample
        else { return }
        // Show it right away: these frames are not a timeline, only "what the prompter looks like now".
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: Events from the system (via PiPBridge)

    fileprivate func didStart() {
        isActive = true
        startWhenPossible = false
    }

    fileprivate func didStop() {
        isActive = false
    }

    fileprivate func failedToStart(_ error: any Error) {
        isActive = false
        lastError = error.localizedDescription
        Journal.shared.error("PiP failed to start", error)
    }

    /// The PiP play/pause button: toggle only when the wish differs from the state.
    fileprivate func setPlaying(_ playing: Bool) {
        if playing == store.state.paused { sendKey(.pipPlayPause) }
    }

    fileprivate func skip(forward: Bool) {
        sendKey(forward ? .pipSkipForward : .pipSkipBack)
    }

    private func sendKey(_ key: HardwareKey) {
        if !store.handle(key), !store.settings.keyControl, let action = KeyBindings.default[key] {
            // Remote keys are off in Settings, but the buttons in the window are not keys: they still work.
            store.perform(action)
        }
        controller?.invalidatePlaybackState()
    }
}

extension AVPictureInPictureController {
    fileprivate func stopPictureInPictureIfActive() {
        if isPictureInPictureActive { stopPictureInPicture() }
    }
}

// MARK: - Delegate bridge

/// The system calls these on its own schedule. State the system reads (`paused`, the time range) lives behind
/// `Mutex`es so any thread can answer; everything else hops to the main actor.
private final class PiPBridge: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate,
    @unchecked Sendable
{
    private let state = Mutex<(paused: Bool, duration: Double)>((false, 60))
    /// Set once, on the main actor, right after creation.
    weak var owner: PiPPrompter?

    func update(paused: Bool, durationSeconds: Double) {
        state.withLock { $0 = (paused, durationSeconds) }
    }

    // AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor [weak self] in self?.owner?.setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // VERIFY(device): a finite range keeps the skip buttons in the window (an infinite one means "live", without them).
        // The length is the script's reading time, so the progress bar means something.
        let seconds = state.withLock { $0.duration }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        state.withLock { $0.paused }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        let forward = skipInterval.seconds >= 0
        Task { @MainActor [weak self] in
            self?.owner?.skip(forward: forward)
            completionHandler()
        }
    }

    // AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.owner?.didStart() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.owner?.didStop() }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.owner?.failedToStart(PiPStartError(message: message)) }
    }
}

private struct PiPStartError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Host view

/// The inline view whose layer PiP floats. It shows a live preview of the window's content.
private struct PiPHostView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let onAttach: @MainActor () -> Void

    func makeUIView(context: Context) -> PiPLayerView {
        let view = PiPLayerView()
        view.attach(layer)
        onAttach()
        return view
    }

    func updateUIView(_ view: PiPLayerView, context: Context) {}
}

private final class PiPLayerView: UIView {
    private weak var hosted: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        backgroundColor = .black
        layer.removeFromSuperlayer()
        self.layer.addSublayer(layer)
        hosted = layer
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}
