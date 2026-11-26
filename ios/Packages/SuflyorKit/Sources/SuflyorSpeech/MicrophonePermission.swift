import AVFAudio

/// Microphone permission (the Info.plist usage text belongs to the app target).
public enum MicrophonePermission {
    public static var isGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Asks once; later calls return the stored answer without a prompt.
    public static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
