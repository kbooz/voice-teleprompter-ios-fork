import SuflyorDomain
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Ready to record

/// Microphone, camera and a speech model: what recording with voice following needs (Android: `ReadinessPage`).
struct ReadinessPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let readiness = env.readiness
        Form {
            Section {
                row(
                    title: L10n.text("settings_mic_title"),
                    hint: L10n.text("ios_app_ready_mic_hint"),
                    done: readiness.mic,
                    blocked: env.microphoneBlocked
                ) { Task { _ = await env.ensureMicrophone() } }
                row(
                    title: L10n.text("ios_app_ready_camera_title"),
                    hint: L10n.text("ios_app_ready_camera_hint"),
                    done: readiness.camera,
                    blocked: env.cameraBlocked
                ) { Task { _ = await env.ensureCamera() } }
                if readiness.speechModel {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("settings_packs_title"))
                            Text(L10n.text("ios_app_ready_model_done")).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    NavigationLink(value: Route.settingsPage(.voice)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("settings_packs_title"))
                            Text(L10n.text("settings_ready_pack_hint")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                if env.microphoneBlocked || env.cameraBlocked {
                    Text(L10n.text("ios_app_ready_blocked_hint"))
                }
            }
        }
    }

    private func row(
        title: String,
        hint: String,
        done: Bool,
        blocked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityHidden(true)
            } else {
                Button(L10n.text(blocked ? "settings_action_open" : "settings_action_allow")) {
                    if blocked { env.openSystemSettings() } else { action() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Text over the camera

struct CameraTextPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let s = store.settings
        Form {
            Section {
                Text(L10n.text("settings_overlay_page_hint"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                SettingStepper(
                    title: L10n.text("settings_lines_title"),
                    display: "\(s.visibleLines)",
                    value: store.binding(\.visibleLines),
                    range: 1...8,
                    step: 1
                )
                SettingStepper(
                    title: L10n.text("settings_side_width_title"),
                    display: "\(s.sideWidthPercent)%",
                    value: store.binding(\.sideWidthPercent),
                    range: SettingLimits.minSideWidth...SettingLimits.maxSideWidth,
                    step: SettingLimits.sideWidthStep
                )
                SettingStepper(
                    title: L10n.text("settings_font_title"),
                    display: "\(Int(s.fontSize))",
                    value: store.binding(\.fontSize),
                    range: 14...48,
                    step: 2
                )
                SettingStepper(
                    title: L10n.text("settings_opacity_title"),
                    hint: L10n.text("settings_opacity_hint"),
                    display: "\(s.backgroundOpacity)%",
                    value: store.binding(\.backgroundOpacity),
                    range: 24...96,
                    step: 8
                )
                SettingStepper(
                    title: L10n.text("settings_margin_start_title"),
                    display: L10n.text("ios_app_points_value", Int(s.paddingStart)),
                    value: store.binding(\.paddingStart),
                    range: 0...60,
                    step: 2
                )
                SettingStepper(
                    title: L10n.text("settings_margin_end_title"),
                    display: L10n.text("ios_app_points_value", Int(s.paddingEnd)),
                    value: store.binding(\.paddingEnd),
                    range: 0...60,
                    step: 2
                )
            }
            Section(L10n.text("ios_app_recording_section")) {
                Picker(L10n.text("ios_app_record_fps"), selection: store.binding(\.recordFrameRate)) {
                    Text(L10n.text("ios_app_fps_value", 30)).tag(30)
                    Text(L10n.text("ios_app_fps_value", 60)).tag(60)
                }
                SettingToggle(
                    title: L10n.text("ios_app_record_hevc"),
                    hint: L10n.text("ios_app_record_hevc_hint"),
                    isOn: store.binding(\.recordHEVC)
                )
            }
        }
    }
}

// MARK: - Full-screen prompter

struct FullScreenPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let s = store.settings
        Form {
            Section {
                Text(L10n.text("settings_fullscreen_page_hint"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                SettingStepper(
                    title: L10n.text("settings_font_title"),
                    display: "\(Int(s.fullScreenFontSize))",
                    value: store.binding(\.fullScreenFontSize),
                    range: SettingLimits.minFullScreenFont...SettingLimits.maxFullScreenFont,
                    step: 4
                )
            }
            Section {
                Picker(L10n.text("settings_mirror_title"), selection: store.mirrorBinding) {
                    ForEach(MirrorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.text("settings_mirror_title"))
            } footer: {
                Text(L10n.text("settings_mirror_pick_hint"))
            }
        }
    }
}

// MARK: - Voice following

struct VoicePage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var showPackPicker = false

    var body: some View {
        let s = store.settings
        // The revisions are read so the pack list refreshes after an install or a removal.
        let _ = env.packsRevision
        Form {
            Section {
                Picker(L10n.text("settings_speech_lang_default_title"), selection: store.binding(\.speechLanguage)) {
                    Text(L10n.text("speech_lang_auto")).tag("auto")
                    ForEach(SpeechLanguage.allCases, id: \.self) { language in
                        Text(language.label).tag(language.code)
                    }
                }
            } footer: {
                if s.speechLanguage == "auto" {
                    // Auto names the language it picked for the current script, so a wrong guess is visible here.
                    Text(L10n.text("settings_speech_lang_auto_hint", detectedName))
                } else {
                    Text(L10n.text("settings_speech_lang_default_hint"))
                }
            }

            Section {
                Picker(L10n.text("ios_app_engine_title"), selection: store.binding(\.asrEngine)) {
                    Text(L10n.text("ios_app_engine_sherpa")).tag(AsrEngineKind.sherpa)
                    Text(L10n.text("ios_app_engine_apple")).tag(AsrEngineKind.apple)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.text("ios_app_engine_title"))
            } footer: {
                Text(L10n.text(s.asrEngine == .sherpa ? "ios_app_engine_sherpa_hint" : "ios_app_engine_apple_hint"))
            }

            Section {
                SettingStepper(
                    title: L10n.text("settings_lead_title"),
                    hint: L10n.text("settings_lead_hint"),
                    display: L10n.text("settings_lead_value", s.leadWords),
                    value: store.binding(\.leadWords),
                    range: 0...4,
                    step: 1
                )
                SettingToggle(
                    title: L10n.text("settings_highlight_title"),
                    hint: L10n.text("settings_highlight_hint"),
                    isOn: store.binding(\.wordHighlight)
                )
                SettingToggle(
                    title: L10n.text("settings_hotwords_title"),
                    hint: L10n.text("settings_hotwords_hint"),
                    isOn: store.binding(\.useHotwords)
                )
            }

            Section {
                ForEach(env.packs.catalog) { pack in
                    packRow(pack)
                }
                Button {
                    showPackPicker = true
                } label: {
                    Text(env.installingPack ? L10n.text("ios_app_pack_installing") : L10n.text("settings_pack_install_file"))
                }
                .disabled(env.installingPack)
            } header: {
                Text(L10n.text("settings_packs_title"))
            } footer: {
                Text(L10n.text(hasBundledModels ? "settings_packs_hint" : "settings_packs_hint_lite"))
            }
        }
        .fileImporter(isPresented: $showPackPicker, allowedContentTypes: [.zip]) { result in
            let env = self.env
            guard case .success(let url) = result else { return }
            Task { @MainActor in await env.installPack(at: url) }
        }
    }

    private var hasBundledModels: Bool {
        SpeechLanguage.allCases.contains { env.packs.isBundled($0) }
    }

    /// What Auto picks for the current script.
    private var detectedName: String {
        guard let document = library.current else { return "" }
        var plain = document
        plain.speechLanguage = nil
        return speechLanguageDisplayName(env.core.detectLanguage(plain.paragraphs))
    }

    private func packRow(_ pack: SpeechPackInfo) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file)
        let bundled = env.packs.isBundled(pack.language)
        let installed = env.packs.isInstalled(pack.language)
        let status = bundled
            ? L10n.text("ios_app_pack_bundled")
            : installed
            ? L10n.text("settings_pack_installed", size)
            : L10n.text("settings_pack_not_installed", size)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(speechLanguageTitle(pack.language))
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !bundled {
                if installed {
                    Button(L10n.text("settings_pack_delete")) { env.removePack(pack.language) }
                        .buttonStyle(.bordered)
                } else {
                    Button(L10n.text("settings_pack_download")) {
                        // The browser downloads the pack: the app itself never connects anywhere.
                        Journal.shared.info("Speech pack \(pack.language.code): opening the download in the browser")
                        openURL(env.packs.downloadURL(for: pack))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - Timed scrolling

struct TimedPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let s = store.settings
        Form {
            Section {
                Text(L10n.text("settings_timed_page_hint"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                SettingStepper(
                    title: L10n.text("settings_wpm_title"),
                    hint: L10n.text("settings_wpm_hint"),
                    display: "\(s.autoScrollWpm)",
                    value: store.binding(\.autoScrollWpm),
                    range: SettingLimits.minWpm...SettingLimits.maxWpm,
                    step: SettingLimits.wpmStep
                )
                SettingStepper(
                    title: L10n.text("settings_countdown_title"),
                    hint: L10n.text("settings_countdown_hint"),
                    display: s.countdownSeconds == 0
                        ? L10n.text("settings_countdown_off")
                        : L10n.text("settings_countdown_value", s.countdownSeconds),
                    value: store.binding(\.countdownSeconds),
                    range: 0...5,
                    step: 1
                )
            }
        }
    }
}

// MARK: - Text

struct TextPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let s = store.settings
        Form {
            Section {
                SettingToggle(
                    title: L10n.text("settings_phrase_title"),
                    hint: L10n.text("settings_phrase_hint"),
                    isOn: store.binding(\.phraseMode)
                )
                if s.phraseMode {
                    SettingStepper(
                        title: L10n.text("settings_max_words_title"),
                        display: L10n.text("settings_max_words_value", s.maxWords),
                        value: store.binding(\.maxWords),
                        range: 3...14,
                        step: 1
                    )
                }
            }
        }
    }
}

// MARK: - Remote keys

struct KeysPage: View {
    @Environment(SettingsStore.self) private var store

    private static let groups: [(title: String, keys: [HardwareKey])] = [
        ("ios_app_keys_group_camera", [.capturePrimary, .captureSecondary]),
        ("ios_app_keys_group_keyboard", [
            .space, .enter, .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .pageUp, .pageDown,
            .mediaPlayPause, .mediaNext, .mediaPrevious,
        ]),
        ("ios_app_keys_group_pip", [.pipPlayPause, .pipSkipForward, .pipSkipBack]),
    ]

    var body: some View {
        Form {
            Section {
                SettingToggle(
                    title: L10n.text("settings_keys_title"),
                    hint: L10n.text("settings_keys_hint"),
                    isOn: store.binding(\.keyControl)
                )
            }
            ForEach(Self.groups, id: \.title) { group in
                Section {
                    ForEach(group.keys, id: \.self) { key in
                        Picker(key.title, selection: store.actionBinding(for: key)) {
                            Text(L10n.text("settings_key_none")).tag(KeyAction?.none)
                            ForEach(KeyAction.allCases, id: \.self) { action in
                                Text(action.title).tag(KeyAction?.some(action))
                            }
                        }
                    }
                } header: {
                    Text(L10n.text(group.title))
                } footer: {
                    if group.title == "ios_app_keys_group_camera" {
                        Text(L10n.text("ios_app_keys_camera_hint"))
                    }
                }
            }
            Section {
                Button(L10n.text("settings_keys_reset")) { store.resetKeyBindings() }
            }
        }
    }
}

// MARK: - Scripts: backup and restore

struct ScriptsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showRestore = false
    @State private var backup: BackupFile?
    @State private var showBackupExporter = false

    var body: some View {
        Form {
            Section {
                Text(L10n.text("settings_scripts_page_hint"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                linkRow(title: "settings_backup_title", hint: "settings_backup_hint", symbol: "square.and.arrow.down") {
                    guard let made = env.makeBackup() else { return }
                    backup = BackupFile(data: made.data, count: made.count)
                    showBackupExporter = true
                }
                linkRow(title: "settings_restore_title", hint: "settings_restore_hint", symbol: "arrow.counterclockwise") {
                    showRestore = true
                }
            }
        }
        .scriptFileImporter(isPresented: $showRestore, zipOnly: true)
        .backupExporter(isPresented: $showBackupExporter, file: backup)
    }

    private func linkRow(title: String, hint: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                    Text(L10n.text(hint)).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .tint(.primary)
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        Form {
            Section {
                SettingToggle(
                    title: L10n.text("settings_diag_title"),
                    hint: L10n.text("settings_diag_hint"),
                    isOn: store.binding(\.showDiagnostics)
                )
            }
            Section {
                NavigationLink(value: Route.journal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("journal_title"))
                        Text(L10n.text("settings_log_hint")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @Environment(AppEnvironment.self) private var env

    private static let siteURL = URL(string: "https://olerast67.github.io/voice-teleprompter-android/")!
    private static let repoURL = URL(string: "https://github.com/olerast67/voice-teleprompter-android")!

    var body: some View {
        Form {
            Section {
                Button { env.openSystemSettings() } label: {
                    row(L10n.text("settings_language_title"), L10n.text("ios_app_language_hint"))
                }
                NavigationLink(value: Route.journal) {
                    row(L10n.text("journal_title"), L10n.text("settings_log_hint"))
                }
            }
            // Links open in the browser: the app itself has no network code.
            Section {
                Link(destination: Self.siteURL) { row(L10n.text("settings_link_site"), Self.siteURL.absoluteString) }
                Link(destination: Self.repoURL) { row(L10n.text("settings_link_code"), Self.repoURL.absoluteString) }
                Link(destination: Self.repoURL.appendingPathComponent("issues/new/choose")) {
                    row(L10n.text("settings_link_issue"), L10n.text("settings_link_issue_hint"))
                }
                Link(destination: Self.repoURL.appendingPathComponent("blob/main/DONATE.md")) {
                    row(L10n.text("settings_link_donate"), L10n.text("settings_link_donate_hint"))
                }
            }
            Section {
                NavigationLink(value: Route.licenses) { Text(L10n.text("ios_app_licenses_title")) }
                NavigationLink(value: Route.privacy) { Text(L10n.text("ios_app_privacy_title")) }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("settings_about_license"))
                    Text("Suflyor \(SettingsHomeView.appVersion)")
                    Text(L10n.text("ios_app_about_engines"))
                }
            }
        }
    }

    private func row(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
