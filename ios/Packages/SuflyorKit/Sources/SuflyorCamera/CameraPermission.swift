import AVFoundation

/// Camera and microphone access, both needed to record with sound. The Photos permission is separate and asked
/// only when a recording is saved (add-only).
public enum CameraPermission {
    /// Both already allowed.
    public static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// The user said no to one of them (or a profile forbids it): asking again shows nothing, Settings is the way.
    public static var isDenied: Bool {
        [AVMediaType.video, .audio].contains { type in
            let status = AVCaptureDevice.authorizationStatus(for: type)
            return status == .denied || status == .restricted
        }
    }

    /// Asks for what is still undecided and says whether both are allowed now.
    public static func request() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return video && audio
    }
}
