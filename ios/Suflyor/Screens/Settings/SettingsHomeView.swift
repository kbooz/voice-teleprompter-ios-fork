import SuflyorDomain
import SwiftUI

/// The list of settings pages with a one-line summary each (Android: `SettingsHome`).
struct SettingsHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let readiness = env.readiness
        List {
            ForEach(SettingsPage.allCases) { page in
                let warn = page == .readiness && !readiness.isComplete
                NavigationLink(value: Route.settingsPage(page)) {
                    HStack(spacing: 14) {
                        Image(systemName: warn ? "exclamationmark.triangle" : page.systemImage)
                            .frame(width: 34, height: 34)
                            .foregroundStyle(warn || page == .readiness ? Color.accentColor : Color.secondary)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title)
                            Text(summary(of: page, readiness: readiness))
                                .font(.subheadline)
                                .foregroundStyle(warn ? Color.accentColor : Color.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("settings_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(of page: SettingsPage, readiness: Readiness) -> String {
        let s = store.settings
        switch page {
        case .readiness:
            return readiness.isComplete
                ? L10n.text("settings_sum_ready_all")
                : L10n.text("settings_sum_ready_part", readiness.doneCount, Readiness.total)
        case .cameraText:
            return L10n.text("settings_sum_overlay", s.visibleLines, Int(s.fontSize), s.backgroundOpacity)
        case .fullScreen:
            return L10n.text("settings_sum_fullscreen", Int(s.fullScreenFontSize), MirrorMode.of(s).label)
        case .voice:
            let language = SpeechLanguage(code: s.speechLanguage)?.label ?? L10n.text("speech_lang_auto")
            return L10n.text("settings_sum_voice", language)
        case .timed:
            let countdown = s.countdownSeconds == 0
                ? L10n.text("settings_countdown_off")
                : L10n.text("settings_countdown_value", s.countdownSeconds)
            return L10n.text("settings_sum_timed", s.autoScrollWpm, countdown)
        case .text:
            return s.phraseMode
                ? L10n.text("settings_sum_text_phrases", s.maxWords)
                : L10n.text("settings_sum_text_paragraphs")
        case .keys:
            return L10n.text(s.keyControl ? "settings_sum_keys_on" : "settings_sum_keys_off")
        case .scripts:
            return L10n.text("settings_sum_scripts")
        case .advanced:
            return L10n.text("ios_app_sum_advanced")
        case .about:
            return L10n.text("settings_sum_about", Self.appVersion)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

/// One page of Settings.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        Group {
            switch page {
            case .readiness: ReadinessPage()
            case .cameraText: CameraTextPage()
            case .fullScreen: FullScreenPage()
            case .voice: VoicePage()
            case .timed: TimedPage()
            case .text: TextPage()
            case .keys: KeysPage()
            case .scripts: ScriptsPage()
            case .advanced: AdvancedPage()
            case .about: AboutPage()
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
