import SuflyorDomain
import SuflyorSession
import SwiftUI
import UIKit

/// Full-screen prompter that follows the voice inside the app: practice before recording, or the screen under
/// teleprompter glass (mirror), on a stand next to the camera or on a lectern. Remote keys work here too.
///
/// The script must already be in `store` (`store.setScript`). The screen starts the session when it appears and stops
/// it when it goes away.
///
/// Microphone: `SuflyorPrompter` does not depend on `SuflyorSpeech`, so the app hands in the source through
/// `audioFactory`, for example `{ MicrophoneAudioSource() }`. It is called only when the scroll mode listens (voice
/// or sound); timed scrolling runs without a microphone, and switching to a listening mode later starts one then.
/// Without a factory the screen still works, scrolling by time only.
public struct RehearsalScreen: View {
    private let store: SessionStore
    @Binding private var settings: PrompterSettings
    private let audioFactory: @MainActor () -> (any AudioSource)?
    private let onClose: () -> Void

    @State private var showTune = false
    @State private var micStarted = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(
        store: SessionStore,
        settings: Binding<PrompterSettings>,
        audioFactory: @escaping @MainActor () -> (any AudioSource)? = { nil },
        onClose: @escaping () -> Void
    ) {
        self.store = store
        _settings = settings
        self.audioFactory = audioFactory
        self.onClose = onClose
    }

    public var body: some View {
        let state = store.state
        let landscape = verticalSizeClass == .compact
        let hidden = settings.fullScreenControlsHidden
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if !hidden && !landscape { topBar(state, compact: false) }
                if let error = state.error {
                    Text(SessionPresentation.errorText(error))
                        .font(.subheadline)
                        .foregroundStyle(PrompterPalette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }
                ZStack(alignment: .topTrailing) {
                    if let script = store.script {
                        PrompterTextView(
                            script: script,
                            nextToken: state.nextToken,
                            style: PrompterStyle.fullScreen(settings),
                            onTapToken: { store.jump(toToken: $0) }
                        )
                    }
                    CountdownOverlay(value: state.countdown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    if hidden {
                        PrompterIconButton(
                            systemName: "arrow.down.right.and.arrow.up.left",
                            label: L10n.text("rehearsal_show_controls"),
                            size: 40
                        ) { settings.fullScreenControlsHidden = false }
                            .opacity(0.6)
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if settings.showDiagnostics {
                    DiagnosticsLine(state: state, showDiagnostics: true).padding(.horizontal, 20)
                }
                if !hidden {
                    if landscape {
                        landscapeBar(state)
                    } else {
                        transport(state, compact: false)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                    }
                }
            }
        }
        .statusBarHidden(hidden)
        .hardwareKeys(enabled: true, handler: { store.handle($0) })
        .sheet(isPresented: $showTune) {
            TuneSheet(settings: $settings, fullScreen: true)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            store.updateSettings(settings)
            startSession()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            store.stop()
            micStarted = false
        }
        .onChange(of: settings) { _, new in store.updateSettings(new) }
        .onChange(of: store.state.scroll) { _, scroll in
            // Voice and sound need ears: start the microphone the first time one of them is picked.
            if scroll != .auto, !micStarted { startSession() }
        }
    }

    // MARK: Session

    private func startSession() {
        let wantsMic = store.state.scroll != .auto
        let audio = wantsMic ? audioFactory() : nil
        micStarted = audio != nil
        store.start(mode: .rehearsal, audio: audio)
    }

    // MARK: Pieces

    private func topBar(_ state: SessionState, compact: Bool) -> some View {
        HStack(spacing: 10) {
            PrompterIconButton(systemName: "chevron.backward", label: L10n.text("common_cd_back"), size: 36, action: onClose)
            statusView(state)
            tuneButton
            hideButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func statusView(_ state: SessionState) -> some View {
        let status = SessionPresentation.status(state, wpm: settings.autoScrollWpm, compact: false)
        return HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(PrompterPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            LevelMeter(levelDb: state.levelDb, muted: state.interrupted || state.digitalSilence)
                .frame(width: 48)
        }
        .accessibilityElement(children: .combine)
    }

    private var tuneButton: some View {
        Button { showTune = true } label: {
            Text("Aa")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PrompterPalette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(PrompterPalette.surfaceHigh))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("overlay_cd_tune"))
    }

    private var hideButton: some View {
        PrompterIconButton(
            systemName: "arrow.up.left.and.arrow.down.right",
            label: L10n.text("rehearsal_hide_controls"),
            size: 36
        ) { settings.fullScreenControlsHidden = true }
    }

    private func landscapeBar(_ state: SessionState) -> some View {
        // Landscape has little height: everything shares one row under the text.
        HStack(spacing: 12) {
            PrompterIconButton(systemName: "chevron.backward", label: L10n.text("common_cd_back"), size: 36, action: onClose)
            statusView(state).frame(maxWidth: .infinity)
            transport(state, compact: true)
            tuneButton
            hideButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// Restart, line back, pause, line forward and the scroll mode. Compact: smaller, without the mode's name.
    private func transport(_ state: SessionState, compact: Bool) -> some View {
        let small: CGFloat = compact ? 40 : 48
        return HStack(spacing: compact ? 12 : 0) {
            PrompterIconButton(systemName: "arrow.counterclockwise", label: L10n.text("common_cd_restart"), size: small) {
                store.restart()
            }
            if !compact { Spacer(minLength: 0) }
            PrompterIconButton(systemName: "chevron.up", label: L10n.text("common_cd_line_back"), size: small) {
                store.stepLine(-1)
            }
            if !compact { Spacer(minLength: 0) }
            PrompterIconButton(
                systemName: state.paused ? "play.fill" : "pause.fill",
                label: L10n.text(state.paused ? "common_cd_resume" : "common_cd_pause"),
                size: compact ? 52 : 68,
                filled: true
            ) { store.togglePause() }
            if !compact { Spacer(minLength: 0) }
            PrompterIconButton(systemName: "chevron.down", label: L10n.text("common_cd_line_forward"), size: small) {
                store.stepLine(1)
            }
            if !compact { Spacer(minLength: 0) }
            VStack(spacing: 4) {
                PrompterIconButton(
                    systemName: SessionPresentation.icon(for: state.scroll),
                    label: L10n.text("common_cd_scroll_mode"),
                    size: small
                ) { store.setScroll(state.scroll.next) }
                // The mode is named, not only drawn: three icons alone don't say what they do.
                if !compact {
                    Text(SessionPresentation.label(for: state.scroll))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrompterPalette.textSecondary)
                }
            }
        }
    }
}
