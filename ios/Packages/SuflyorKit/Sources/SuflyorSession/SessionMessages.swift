import Foundation
import SuflyorDomain

// What the user sees for an error (Android: `SessionError.message(context)` and `CaptureError.message(context)`).
// Keys are Android's where the meaning is the same; the iOS-only ones are in ios-strings/speech.json.

extension SessionError {
    /// Text for the prompter's diagnostics line.
    public var localizedMessage: String {
        switch self {
        case .asrLoadFailed(let detail): L10n.text("session_error_asr_failed", detail)
        case .packMissing(let language): L10n.text("session_error_pack_missing", language.label)
        case .capture(let error): error.localizedMessage
        }
    }
}

extension CaptureError {
    public var localizedMessage: String {
        switch self {
        case .permissionDenied: L10n.text("ios_speech_error_permission")
        case .sessionActivationFailed(let detail): L10n.text("ios_speech_error_audio_session", detail)
        case .startFailed(let detail): L10n.text("session_error_record_start", detail)
        case .formatUnsupported(let sampleRate): L10n.text("session_error_rate_unsupported", sampleRate)
        case .interruptedForGood: L10n.text("ios_speech_error_interrupted")
        }
    }
}
