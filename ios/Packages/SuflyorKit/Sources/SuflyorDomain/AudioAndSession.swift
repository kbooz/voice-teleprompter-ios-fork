import Foundation

// MARK: - Audio

/// About 100 ms of mono audio at 16 kHz, in [-1, 1] (Kotlin: `AudioCapture.Listener.onAudio`).
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    /// RMS level in dBFS, -120 for silence.
    public var rmsDb: Float
    /// Every sample is exactly zero: the system feeds silence (another app took the microphone).
    public var digitalSilence: Bool

    public init(samples: [Float], sampleRate: Int, rmsDb: Float, digitalSilence: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.rmsDb = rmsDb
        self.digitalSilence = digitalSilence
    }
}

public enum CaptureError: Error, Hashable, Sendable {
    case permissionDenied
    case sessionActivationFailed(String)
    case startFailed(String)
    case formatUnsupported(sampleRate: Int)
    /// The audio session was interrupted and could not be resumed (another app is recording).
    case interruptedForGood
}

public enum AudioEvent: Sendable {
    case chunk(AudioChunk)
    /// `AVAudioSession` interruption began: no audio until `.resumed`.
    case interrupted
    case resumed
    /// Input route changed (AirPods, USB-C mic, built-in): a human-readable description for the journal.
    case routeChanged(String)
    /// The source stopped for good; the stream finishes after this event.
    case failed(CaptureError)
}

/// A microphone feed: `MicrophoneAudioSource` (AVAudioEngine, WP-C) or `CaptureAudioSource`
/// (the camera's `AVCaptureAudioDataOutput`, WP-D). Both deliver 16 kHz mono chunks of ~100 ms.
public protocol AudioSource: AnyObject, Sendable {
    /// Starts capturing. The stream ends after `stop()` or `.failed`. Calling `start()` again restarts the source.
    func start() async throws(CaptureError) -> AsyncStream<AudioEvent>
    func stop()
}

// MARK: - Session

/// How the text moves (Kotlin: `SessionEngine.Scroll`). The mode button steps through them in this order.
public enum ScrollMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Follows the recognized words.
    case voice
    /// Scrolls at a fixed speed (words per minute) after a countdown.
    case auto
    /// Scrolls at that speed only while somebody is talking.
    case sound

    public var next: ScrollMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Where the session shows the text (Android had IN_APP and OVERLAY).
public enum SessionMode: String, Hashable, Sendable {
    case idle
    /// Full-screen prompter inside the app (rehearsal, teleprompter glass).
    case rehearsal
    /// Live front camera behind the text, recording in the app.
    case camera
    /// Picture in Picture over other apps (experimental).
    case pictureInPicture
}

public enum SessionError: Error, Hashable, Sendable {
    /// The recognizer didn't load: the session still runs, without voice following.
    case asrLoadFailed(String)
    /// The script's language needs a speech pack that isn't installed.
    case packMissing(SpeechLanguage)
    case capture(CaptureError)
}

/// Everything the prompter screens draw (Kotlin: `SessionEngine.State`, minus Android-only diagnostics).
public struct SessionState: Hashable, Sendable {
    public var mode: SessionMode = .idle
    public var starting = false
    public var listening = false
    public var paused = false
    public var scroll: ScrollMode = .voice
    /// Voice mode falls back to timed scrolling because the microphone gives only silence or is interrupted.
    public var autoFallback = false
    /// The microphone stopped for good this session: the timer moves the text.
    public var micFailed = false
    /// The audio session is interrupted right now (iOS counterpart of Android's "silenced by system").
    public var interrupted = false
    public var levelDb: Float = -120
    public var digitalSilence = false
    /// Current partial utterance and last final utterance, for the diagnostics line.
    public var partial = ""
    public var lastFinal = ""
    /// Token index of the next word to read (highlight / scroll target).
    public var nextToken = 0
    /// Spoken-word position and the script's spoken-word count.
    public var position = 0
    public var total = 0
    public var error: SessionError?
    /// Seconds left in the 3-2-1 before timed scrolling starts; 0 when there is none.
    public var countdown = 0
    /// The recognizer for the script's language is still loading.
    public var loadingModel = false

    public init() {}
}

// MARK: - Remote keys

/// What a key does (Kotlin: `overlay.KeyAction`).
public enum KeyAction: String, Codable, CaseIterable, Hashable, Sendable {
    case pause
    case back
    case forward
}

/// Hardware inputs the iOS app can see, independent of UIKit (WP-D maps `UIPress`, `AVCaptureEventInteraction`
/// and the PiP buttons onto these).
public enum HardwareKey: String, Codable, CodingKeyRepresentable, CaseIterable, Hashable, Sendable {
    /// Volume down, Action button, Camera Control, AirPods stem: `AVCaptureEventInteraction` primary (camera mode only).
    case capturePrimary
    /// Volume up: `AVCaptureEventInteraction` secondary (camera mode only).
    case captureSecondary
    case space
    case enter
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case pageUp
    case pageDown
    case mediaPlayPause
    case mediaNext
    case mediaPrevious
    /// The play/pause and skip buttons of the Picture in Picture window.
    case pipPlayPause
    case pipSkipForward
    case pipSkipBack
}

/// Which key does what (Kotlin: `overlay.KeyBindings.DEFAULT`, mapped to iOS inputs).
public enum KeyBindings {
    public static let `default`: [HardwareKey: KeyAction] = [
        .captureSecondary: .pause, // Android: volume up → pause
        .capturePrimary: .back, // Android: volume down → back
        .space: .pause,
        .enter: .pause,
        .mediaPlayPause: .pause,
        .pipPlayPause: .pause,
        .mediaNext: .forward,
        .pageDown: .forward,
        .arrowDown: .forward,
        .arrowRight: .forward,
        .pipSkipForward: .forward,
        .mediaPrevious: .back,
        .pageUp: .back,
        .arrowUp: .back,
        .arrowLeft: .back,
        .pipSkipBack: .back,
    ]
}
