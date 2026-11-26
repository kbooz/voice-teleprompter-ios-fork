import SuflyorDomain
import SwiftUI

/// How a `SessionState` looks to the user: status text and colour, error text, the diagnostics line. Shared by the
/// rehearsal screen, the camera screen and the Picture in Picture frame, as Android shares `statusOf`.
package enum SessionPresentation {
    package struct Status {
        package var color: Color
        package var label: String
    }

    /// `compact` uses the short words of the floating window (`overlay_status_*`), otherwise the rehearsal ones.
    package static func status(_ s: SessionState, wpm: Int, compact: Bool) -> Status {
        if s.starting || s.loadingModel {
            return Status(color: PrompterPalette.textMuted, label: L10n.text(compact ? "overlay_status_starting" : "rehearsal_status_starting"))
        }
        // Timed scrolling needs no microphone, so "not listening" would mislead there.
        if !s.listening && s.scroll != .auto {
            return Status(color: PrompterPalette.textMuted, label: L10n.text(compact ? "overlay_status_stopped" : "rehearsal_status_idle"))
        }
        if s.error != nil {
            return Status(color: PrompterPalette.danger, label: L10n.text(compact ? "overlay_status_error" : "rehearsal_status_error"))
        }
        if s.paused {
            return Status(color: PrompterPalette.accent, label: L10n.text(compact ? "overlay_status_paused" : "rehearsal_status_paused"))
        }
        if s.scroll == .auto {
            let label = compact ? L10n.text("overlay_status_auto") : L10n.text("rehearsal_status_auto", wpm)
            return Status(color: PrompterPalette.accent, label: label)
        }
        // Sound mode depends on hearing too: an interrupted microphone must show before "while you talk".
        if s.interrupted {
            return Status(color: PrompterPalette.danger, label: L10n.text(compact ? "overlay_status_mic_busy" : "rehearsal_status_mic_busy"))
        }
        if s.autoFallback || s.micFailed {
            return Status(color: PrompterPalette.danger, label: L10n.text(compact ? "overlay_status_cant_hear" : "rehearsal_status_fallback"))
        }
        if s.scroll == .sound {
            let label = compact ? L10n.text("overlay_status_sound") : L10n.text("rehearsal_status_sound", wpm)
            return Status(color: PrompterPalette.accent, label: label)
        }
        return Status(color: PrompterPalette.success, label: L10n.text(compact ? "overlay_status_listening" : "rehearsal_status_listening"))
    }

    package static func errorText(_ error: SessionError) -> String {
        switch error {
        case .asrLoadFailed(let detail):
            return L10n.text("session_error_asr_failed", detail)
        case .packMissing(let language):
            return L10n.text("session_error_pack_missing", language.label)
        case .capture(let capture):
            switch capture {
            case .permissionDenied: return L10n.text("ios_prompter_error_permission_denied")
            case .sessionActivationFailed(let detail): return L10n.text("ios_prompter_error_session_activation", detail)
            case .startFailed(let detail): return L10n.text("ios_prompter_error_start_failed", detail)
            case .formatUnsupported(let rate): return L10n.text("session_error_rate_unsupported", rate)
            case .interruptedForGood: return L10n.text("ios_prompter_error_mic_busy")
            }
        }
    }

    /// Partial text (or the last final one) and the microphone level, for `settings.showDiagnostics`.
    package static func diagnosticsText(_ s: SessionState) -> String {
        let heard = (s.partial.isEmpty ? s.lastFinal : s.partial).suffix(70)
        let level = s.digitalSilence ? "silence" : String(format: "%.0f dB", Double(s.levelDb))
        return "\(heard)\n\(level) · \(s.position)/\(s.total)"
    }

    package static func icon(for scroll: ScrollMode) -> String {
        switch scroll {
        case .voice: "mic.fill"
        case .auto: "speedometer"
        case .sound: "waveform"
        }
    }

    package static func label(for scroll: ScrollMode) -> String {
        switch scroll {
        case .voice: L10n.text("scroll_mode_voice")
        case .auto: L10n.text("scroll_mode_auto")
        case .sound: L10n.text("scroll_mode_sound")
        }
    }
}

/// Thin microphone level meter; red when the system feeds silence (Android `LevelBar`).
package struct LevelMeter: View {
    let levelDb: Float
    let muted: Bool

    package init(levelDb: Float, muted: Bool) {
        self.levelDb = levelDb
        self.muted = muted
    }

    package var body: some View {
        let fraction = muted ? 1 : Double(min(max((levelDb + 60) / 60, 0), 1))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.24))
                Capsule()
                    .fill(muted ? PrompterPalette.danger : PrompterPalette.success)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("ios_prompter_level"))
    }
}

/// The 3-2-1 before timed scrolling starts.
package struct CountdownOverlay: View {
    let value: Int

    package init(value: Int) { self.value = value }

    package var body: some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(PrompterPalette.accent)
                .shadow(color: .black.opacity(0.7), radius: 6)
                .accessibilityLabel("\(value)")
                .transition(.opacity)
        }
    }
}

/// Partial text, level and any error under the prompter (`settings.showDiagnostics`), in the diagnostics green.
package struct DiagnosticsLine: View {
    let state: SessionState
    let showDiagnostics: Bool

    package init(state: SessionState, showDiagnostics: Bool) {
        self.state = state
        self.showDiagnostics = showDiagnostics
    }

    package var body: some View {
        // An error shows even with diagnostics off: the status row only has room for one word.
        if let error = state.error {
            Text(SessionPresentation.errorText(error))
                .font(.footnote)
                .foregroundStyle(PrompterPalette.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if showDiagnostics {
            Text(SessionPresentation.diagnosticsText(state))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(red: 170 / 255, green: 240 / 255, blue: 190 / 255).opacity(0.75))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Round icon button used by the rehearsal and camera controls.
package struct PrompterIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 48
    var filled = false
    let action: () -> Void

    package init(systemName: String, label: String, size: CGFloat = 48, filled: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.filled = filled
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(filled ? PrompterPalette.onAccent : Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? PrompterPalette.accent : PrompterPalette.surfaceHigh.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
