import SuflyorDomain
import SuflyorImporters
import SuflyorPrompter
import SwiftUI

/// One script: preview, language and speed, and the ways to use it (Android: `ScriptScreen`).
struct ScriptView: View {
    let id: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings

    @State private var confirmDelete = false
    @State private var showLanguage = false
    @State private var showSpeed = false

    private var isCurrent: Bool { library.currentID == id }

    var body: some View {
        Group {
            if isCurrent, let document = library.current, let prepared = library.prepared {
                content(document: document, prepared: prepared)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(isCurrent ? (library.current?.title ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        // Deep links and the Back button can arrive with another script selected.
        .task(id: id) { if library.currentID != id { library.select(id) } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isCurrent, let document = library.current {
                    Button { env.router.path.append(.editor(id)) } label: {
                        Label(L10n.text("script_cd_edit"), systemImage: "pencil")
                    }
                    ShareLink(item: ScriptArchive.markdown(of: document), subject: Text(document.title)) {
                        Label(L10n.text("script_cd_share"), systemImage: "square.and.arrow.up")
                    }
                    Menu {
                        Button { duplicate() } label: {
                            Label(L10n.text("script_cd_duplicate"), systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label(L10n.text("common_delete"), systemImage: "trash")
                        }
                    } label: {
                        Label(L10n.text("library_cd_menu"), systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .alert(L10n.text("script_delete_title"), isPresented: $confirmDelete) {
            Button(L10n.text("common_delete"), role: .destructive) { delete() }
            Button(L10n.text("common_cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("script_delete_message", library.current?.title ?? ""))
        }
        .sheet(isPresented: $showLanguage) {
            LanguageSheet(scriptID: id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSpeed) {
            SpeedSheet()
                .presentationDetents([.height(260)])
        }
    }

    @ViewBuilder
    private func content(document: ImportedDocument, prepared: PreparedScript) -> some View {
        let wpm = settings.settings.autoScrollWpm
        let language = prepared.language
        VStack(spacing: 10) {
            ScriptPreview(script: prepared)
                .padding(.horizontal, 16)

            // What changes per take is one tap away: the language the recognizer listens for, and the timed speed.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(L10n.text("script_lang_chip", speechLanguageDisplayName(language))) { showLanguage = true }
                    chip(L10n.text("speed_value", wpm)) { showSpeed = true }
                }
                .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(
                    "script_stats",
                    formatDuration(prepared.durationSeconds(wpm: wpm)),
                    wordsLabel(prepared.spokenWords),
                    formatLabel(document.format)
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning.message)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)

            actions(language: language)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.secondary)
    }

    @ViewBuilder
    private func actions(language: SpeechLanguage) -> some View {
        let readiness = env.readiness
        VStack(spacing: 10) {
            if !readiness.mic {
                setupCard(L10n.text("script_setup_mic")) { Task { _ = await env.ensureMicrophone() } }
            } else if settings.settings.asrEngine == .sherpa, !env.packs.isAvailable(language) {
                setupCard(L10n.text("session_error_pack_missing", language.label)) {
                    env.router.path.append(.settingsPage(.voice))
                }
            }
            Button {
                Task { await env.startCamera() }
            } label: {
                Label(L10n.text("ios_app_action_record"), systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 10) {
                Button {
                    Task { await env.startRehearsal() }
                } label: {
                    Label(L10n.text("script_action_rehearse"), systemImage: "mic")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if PiPPrompter.isSupported {
                    Button {
                        env.openPictureInPictureSheet()
                    } label: {
                        Label(L10n.text("ios_app_action_pip"), systemImage: "pip")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    private func setupCard(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .tint(.primary)
    }

    private func duplicate() {
        if let copy = library.duplicate(id) { env.openScript(copy) }
    }

    private func delete() {
        library.delete(id)
        env.router.pop()
    }
}

/// The script as the prompter draws it, tappable to move the position. Alone in its own view, so the fast
/// `session.state` updates don't redraw the rest of the screen.
private struct ScriptPreview: View {
    let script: PreparedScript
    @Environment(SessionStore.self) private var session
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PrompterTextView(
                script: script,
                nextToken: session.state.nextToken,
                style: .fullScreen(settings.settings),
                onTapToken: { session.jump(toToken: $0) }
            )
            if session.state.position > 0 {
                Button { session.restart() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .tint(.white)
                .padding(10)
                .accessibilityLabel(L10n.text("common_cd_restart"))
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The speech language of this script (Android: the language bottom sheet).
private struct LanguageSheet: View {
    let scriptID: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let document = library.document(id: scriptID)
        let followed = defaultLanguage(for: document)

        NavigationStack {
            List {
                Section {
                    Text(L10n.text("script_lang_sheet_hint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    option(
                        title: L10n.text("script_lang_follow", followed.map(speechLanguageDisplayName) ?? ""),
                        selected: document?.speechLanguage == nil
                    ) { choose(nil) }
                    ForEach(SpeechLanguage.allCases, id: \.self) { language in
                        option(title: title(for: language), selected: document?.speechLanguage == language) {
                            choose(language)
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("script_lang_sheet_title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// What "as in Settings" resolves to: the script's own choice left out.
    private func defaultLanguage(for document: ImportedDocument?) -> SpeechLanguage? {
        guard var plain = document else { return nil }
        plain.speechLanguage = nil
        return settings.settings.resolvedLanguage(for: plain, core: env.core)
    }

    private func title(for language: SpeechLanguage) -> String {
        let missing = settings.settings.asrEngine == .sherpa && !env.packs.isAvailable(language)
        return missing ? "\(language.label) · \(L10n.text("script_lang_pack_missing"))" : language.label
    }

    private func option(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
    }

    private func choose(_ language: SpeechLanguage?) {
        library.setSpeechLanguage(scriptID, to: language)
        dismiss()
    }
}

/// Speed without voice: the timed and sound modes and the length estimate.
private struct SpeedSheet: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SettingStepper(
                        title: L10n.text("settings_wpm_title"),
                        hint: L10n.text("speed_unit"),
                        display: "\(settings.settings.autoScrollWpm)",
                        value: settings.binding(\.autoScrollWpm),
                        range: SettingLimits.minWpm...SettingLimits.maxWpm,
                        step: SettingLimits.wpmStep
                    )
                } footer: {
                    Text(L10n.text("script_speed_sheet_hint"))
                }
            }
            .navigationTitle(L10n.text("script_speed_sheet_title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// "Over another app": the floating window. The host view has to be on screen when the window starts, so it
/// starts from here, not from a bare button.
struct PictureInPictureSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.text("ios_app_pip_hint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker(L10n.text("ios_app_pip_target"), selection: settings.binding(\.overlayTarget)) {
                        ForEach(OverlayTarget.allCases.filter { $0.isAvailable }, id: \.self) { target in
                            Text(target.label).tag(target)
                        }
                    }
                }
                Section {
                    env.pip.hostView
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    if env.pictureInPictureRunning {
                        Button(role: .destructive) {
                            env.stopPictureInPicture()
                        } label: {
                            Text(L10n.text("ios_app_pip_stop")).frame(maxWidth: .infinity)
                        }
                    } else {
                        Button {
                            Task { await env.startPictureInPicture() }
                        } label: {
                            Text(L10n.text("ios_app_pip_start")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } footer: {
                    Text(L10n.text("ios_app_pip_limits"))
                }
            }
            .navigationTitle(L10n.text("ios_app_action_pip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("editor_action_done")) { dismiss() }
                }
            }
        }
        // Closing the sheet ends the window and the session behind it.
        .onDisappear { env.stopPictureInPicture() }
    }
}
