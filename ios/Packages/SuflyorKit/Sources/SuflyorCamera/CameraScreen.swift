import AVFoundation
import AVKit
import SuflyorDomain
import SuflyorPrompter
import SuflyorSession
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Front camera live behind the text, recording with sound, saving to Photos and sharing.
///
/// The text sits in a band at the top, right under the Dynamic Island, so the reader's eyes stay close to the lens;
/// held sideways the band moves next to the lens (Android's `Placement`). The text is only drawn on screen: the
/// recorded file has no captions. The script must already be in `store`.
///
/// The camera screen owns the microphone: it starts the capture session first and then hands the session store a
/// `CaptureAudioSource` fed by that same session, so voice following hears what is recorded and nothing else.
public struct CameraScreen: View {
    private let store: SessionStore
    @Binding private var settings: PrompterSettings
    private let onClose: () -> Void

    @State private var model = CameraModel()
    @State private var showTune = false
    @Environment(\.scenePhase) private var scenePhase

    public init(store: SessionStore, settings: Binding<PrompterSettings>, onClose: @escaping () -> Void) {
        self.store = store
        _settings = settings
        self.onClose = onClose
    }

    public var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let lens = LensSide.current(landscape: landscape)
            ZStack {
                Color.black
                CameraPreview(recorder: model.recorder)
                if model.access == .denied {
                    permissionCard
                } else {
                    band(geo: geo, landscape: landscape, lens: lens)
                    statusChip(geo: geo, landscape: landscape, lens: lens)
                    controls(geo: geo, landscape: landscape, lens: lens)
                    CountdownOverlay(value: store.state.countdown).allowsHitTesting(false)
                    notices(geo: geo)
                    if let finished = model.finished { finishedCard(finished) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Physical layout: the lens is on the physical left or right, whatever the language's direction.
        .environment(\.layoutDirection, .leftToRight)
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .hardwareKeys(enabled: true, handler: { store.handle($0) })
        // VERIFY: the iOS 18 two-handler form of onCameraCaptureEvent: volume down, Action button, Camera Control and
        // AirPods stem are "primary"; volume up is "secondary". Only works while a capture session runs.
        .onCameraCaptureEvent(
            isEnabled: model.ready,
            defaultSoundDisabled: true,
            primaryAction: { event in
                guard event.phase == .ended else { return }
                // An unbound primary key is the shutter: record or stop.
                if !store.handle(.capturePrimary) { Task { await model.toggleRecording(settings: settings) } }
            },
            secondaryAction: { event in
                guard event.phase == .ended else { return }
                _ = store.handle(.captureSecondary)
            }
        )
        .sheet(isPresented: $showTune) {
            TuneSheet(settings: $settings, fullScreen: false)
        }
        .task {
            store.updateSettings(settings)
            await model.start(store: store, settings: settings)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            store.stop()
            Task { await model.shutdown() }
        }
        .onChange(of: settings) { _, new in store.updateSettings(new) }
        .onChange(of: scenePhase) { _, phase in
            // The camera stops in the background: keep what has been recorded.
            if phase == .background { Task { await model.finishRecordingIfNeeded() } }
        }
    }

    // MARK: Text band

    /// The over-camera style with the band's placement folded in: the text starts under the Dynamic Island in portrait,
    /// and its margin on the lens side grows by the cut-out's depth when sideways.
    private func bandStyle(geo: GeometryProxy, landscape: Bool, lens: LensSide) -> PrompterStyle {
        var style = PrompterStyle.overCamera(settings)
        if landscape {
            if lens == .left {
                style.paddingStart += Double(geo.safeAreaInsets.leading)
            } else {
                style.paddingEnd += Double(geo.safeAreaInsets.trailing)
            }
        } else {
            style.topInset = Double(geo.safeAreaInsets.top) + PrompterStyle.defaultTopInset
        }
        return style
    }

    @ViewBuilder
    private func band(geo: GeometryProxy, landscape: Bool, lens: LensSide) -> some View {
        if let script = store.script {
            let style = bandStyle(geo: geo, landscape: landscape, lens: lens)
            let text = PrompterTextView(
                script: script,
                nextToken: store.state.nextToken,
                style: style,
                onTapToken: { store.jump(toToken: $0) }
            )
            if landscape {
                // Next to the lens: full height, a fraction of the width.
                let fraction = Double(min(max(settings.sideWidthPercent, 28), 100)) / 100
                text
                    .frame(width: geo.size.width * fraction, height: geo.size.height)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: lens == .left ? 0 : 22,
                        bottomLeadingRadius: lens == .left ? 0 : 22,
                        bottomTrailingRadius: lens == .left ? 22 : 0,
                        topTrailingRadius: lens == .left ? 22 : 0
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lens == .left ? .leading : .trailing)
            } else {
                text
                    .frame(width: geo.size.width, height: style.preferredHeight)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private func statusChip(geo: GeometryProxy, landscape: Bool, lens: LensSide) -> some View {
        let state = store.state
        let status = SessionPresentation.status(state, wpm: settings.autoScrollWpm, compact: true)
        let bandHeight = PrompterStyle.overCamera(settings).preferredHeight + Double(geo.safeAreaInsets.top)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text(status.label).font(.caption.weight(.medium)).foregroundStyle(.white)
                LevelMeter(levelDb: state.levelDb, muted: state.interrupted || state.digitalSilence)
                    .frame(width: 44)
            }
            DiagnosticsLine(state: state, showDiagnostics: settings.showDiagnostics)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .frame(maxWidth: 300, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? (lens == .left ? .topTrailing : .topLeading) : .topLeading)
        .padding(landscape ? EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16) : EdgeInsets(top: bandHeight + 8, leading: 16, bottom: 0, trailing: 16))
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(geo: GeometryProxy, landscape: Bool, lens: LensSide) -> some View {
        let state = store.state
        let items = VStackOrHStack(vertical: landscape) {
            PrompterIconButton(
                systemName: SessionPresentation.icon(for: state.scroll),
                label: L10n.text("common_cd_scroll_mode"),
                size: 44
            ) { store.setScroll(state.scroll.next) }
            PrompterIconButton(
                systemName: state.paused ? "play.fill" : "pause.fill",
                label: L10n.text(state.paused ? "common_cd_resume" : "common_cd_pause"),
                size: 44
            ) { store.togglePause() }
            recordButton
            tuneButton
            PrompterIconButton(systemName: "xmark", label: L10n.text("overlay_cd_close"), size: 44) { close() }
        }
        if landscape {
            // On the side away from the lens, so the buttons don't sit on the text.
            items
                .padding(.vertical, 12)
                .padding(lens == .left ? .trailing : .leading, 16 + (lens == .left ? geo.safeAreaInsets.trailing : geo.safeAreaInsets.leading))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lens == .left ? .bottomTrailing : .bottomLeading)
        } else {
            items
                .padding(.horizontal, 20)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var recordButton: some View {
        VStack(spacing: 4) {
            if model.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(PrompterPalette.danger).frame(width: 8, height: 8)
                    Text(CameraModel.clock(model.elapsed))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                Task { await model.toggleRecording(settings: settings) }
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(PrompterPalette.danger).frame(width: 30, height: 30)
                    } else {
                        Circle().fill(PrompterPalette.danger).frame(width: 58, height: 58)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.ready || model.isFinishing)
            .opacity(model.ready ? 1 : 0.4)
            .accessibilityLabel(L10n.text(model.isRecording ? "ios_camera_stop" : "ios_camera_record"))
        }
    }

    private var tuneButton: some View {
        Button { showTune = true } label: {
            Text("Aa")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(PrompterPalette.surfaceHigh.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("overlay_cd_tune"))
    }

    private func close() {
        Task {
            // A take in progress is finished and saved first: closing must not lose it.
            await model.finishRecordingIfNeeded()
            onClose()
        }
    }

    // MARK: Cards and notices

    private func notices(geo: GeometryProxy) -> some View {
        VStack(spacing: 6) {
            if model.hot {
                Label(L10n.text("ios_camera_thermal"), systemImage: "thermometer.high")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(PrompterPalette.danger.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.7)))
                    .foregroundStyle(PrompterPalette.danger)
                    .onTapGesture { model.errorMessage = nil }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(model.errorMessage != nil)
    }

    private func finishedCard(_ recording: CameraModel.Recording) -> some View {
        VStack(spacing: 12) {
            Label(
                L10n.text(recording.savedToPhotos ? "ios_camera_saved_photos" : "ios_camera_not_saved"),
                systemImage: recording.savedToPhotos ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(recording.savedToPhotos ? PrompterPalette.success : PrompterPalette.accent)
            if let note = recording.note {
                Text(note).font(.footnote).multilineTextAlignment(.center).foregroundStyle(PrompterPalette.textSecondary)
            }
            HStack(spacing: 12) {
                ShareLink(item: MovieFile(url: recording.url), preview: SharePreview(recording.url.lastPathComponent)) {
                    Label(L10n.text("ios_camera_share"), systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(PrompterPalette.accent))
                        .foregroundStyle(PrompterPalette.onAccent)
                }
                Button(L10n.text("ios_camera_new_take")) { model.finished = nil }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(PrompterPalette.surfaceHigh))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22).fill(PrompterPalette.surface.opacity(0.96)))
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var permissionCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill").font(.system(size: 36)).foregroundStyle(PrompterPalette.accent)
            Text(L10n.text("ios_camera_permission_title")).font(.headline).foregroundStyle(.white)
            Text(L10n.text("ios_camera_permission_body"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(PrompterPalette.textSecondary)
            Button(L10n.text("ios_camera_open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(PrompterPalette.accent))
            .foregroundStyle(PrompterPalette.onAccent)
            Button(L10n.text("overlay_cd_close"), action: onClose).foregroundStyle(PrompterPalette.textSecondary)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 22).fill(PrompterPalette.surface))
        .padding(24)
    }
}

// MARK: - Sharing

/// The recorded file as something the share sheet can send: as a file, not as a link to the temporary folder.
private struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // VERIFY: FileRepresentation with SentTransferredFile is the documented way to share a file URL.
        FileRepresentation(exportedContentType: .quickTimeMovie) { movie in
            SentTransferredFile(movie.url)
        }
    }
}

// MARK: - Placement

/// Where the front lens is, as the screen is held. Portrait: at the top, and the text band hangs from there.
enum LensSide {
    case top
    case left
    case right

    /// The Dynamic Island sits at the top of the phone. Seen from the screen, that is the left edge when the
    /// interface is `landscapeRight` and the right edge when it is `landscapeLeft` (the interface orientation names
    /// the side the home indicator is on, which is the opposite of the device orientation's).
    @MainActor
    static func current(landscape: Bool) -> LensSide {
        guard landscape else { return .top }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // VERIFY: `effectiveGeometry.interfaceOrientation` (iOS 16+) is the non-deprecated way to read the orientation.
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: return .right
        case .landscapeRight: return .left
        default: return .left
        }
    }
}

/// The same buttons in a column or in a row.
private struct VStackOrHStack<Content: View>: View {
    let vertical: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if vertical {
            VStack(spacing: 10) { content() }
        } else {
            HStack(spacing: 0) { content().frame(maxWidth: .infinity) }
        }
    }
}

// MARK: - Preview

private struct CameraPreview: UIViewRepresentable {
    let recorder: CameraRecorder

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = recorder.session
        view.previewLayer.videoGravity = .resizeAspectFill
        // The preview mirrors by itself (selfie): the text on screen and the face move the way people expect.
        recorder.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass guarantees the type.
        layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
    }
}
