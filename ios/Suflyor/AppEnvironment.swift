import AVFoundation
import Foundation
import Observation
import SuflyorCamera
import SuflyorDomain
import SuflyorImporters
import SuflyorPrompter
import SuflyorSession
import SuflyorSpeech
import SwiftData
import SwiftUI
import UIKit

/// What the recording flows need, checked on every foreground (Android: `Readiness`).
struct Readiness {
    var mic: Bool
    var camera: Bool
    /// A speech model is there: bundled (full build), an installed pack, or the Apple engine.
    var speechModel: Bool

    static let total = 3
    var doneCount: Int { [mic, camera, speechModel].filter { $0 }.count }
    var isComplete: Bool { doneCount == Self.total }
}

/// Builds and owns everything the screens use (docs/ios/contratos.md, section 3.6) and hands it out with `.environment`.
@MainActor @Observable
final class AppEnvironment {
    let core: KMPScriptCore
    let packs: SpeechPackStore
    let engines: SpeechEngineFactory
    let sessionEngine: SessionEngine
    let session: SessionStore
    let importer: DocumentImporter
    let settings: SettingsStore
    let library: LibraryStore
    let router: AppRouter
    let pip: PiPPrompter

    /// A short message at the bottom of the screen (Android: Toast).
    private(set) var toastMessage: String?
    /// Bumped when something the screens can't observe by itself changed: permissions, installed packs.
    private(set) var permissionRevision = 0
    private(set) var packsRevision = 0
    private(set) var installingPack = false
    /// True from "Start" to "Stop" of the floating window.
    var pictureInPictureRunning = false

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var inboxBusy = false

    init() {
        let settings = SettingsStore()
        let core = KMPScriptCore()
        let packs = SpeechPackStore()
        let engines = SpeechEngineFactory(packs: packs)
        // The engine is an actor: nothing here touches the microphone or loads a model yet.
        let sessionEngine = SessionEngine(core: core, engines: engines, packs: packs, settings: settings.settings)
        let session = SessionStore(engine: sessionEngine, settings: settings.settings)
        let library = LibraryStore(container: Self.makeContainer(), core: core, settings: settings)

        self.core = core
        self.packs = packs
        self.engines = engines
        self.sessionEngine = sessionEngine
        self.session = session
        self.importer = DocumentImporter(core: core)
        self.settings = settings
        self.library = library
        self.router = AppRouter()
        self.pip = PiPPrompter(store: session)

        settings.onChange = { [weak self] old, new in self?.settingsChanged(old: old, new: new) }
        library.onPrepared = { [session] script in session.setScript(script) }
        // The first layout happened inside LibraryStore.init, before the callback existed.
        if let prepared = library.prepared { session.setScript(prepared) }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Journal.shared.info("Suflyor \(version), iOS \(UIDevice.current.systemVersion)")
    }

    private static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: StoredScript.self)
        } catch {
            Journal.shared.error("Couldn't open the library store, keeping scripts in memory only", error)
            do {
                return try ModelContainer(
                    for: StoredScript.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("SwiftData can't create even an in-memory store: \(error)")
            }
        }
    }

    // MARK: - Settings

    private func settingsChanged(old: PrompterSettings, new: PrompterSettings) {
        session.updateSettings(new)
        let languageChanged = old.speechLanguage != new.speechLanguage
        // Word matching and counting depend on the language: re-layout, recount the library.
        if languageChanged { library.recountAll() }
        if languageChanged || old.phraseMode != new.phraseMode || old.maxWords != new.maxWords {
            library.relayout()
        }
    }

    // MARK: - Messages

    func showToast(_ text: String) {
        toastMessage = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Readiness and permissions

    var readiness: Readiness {
        // Read so that views showing it refresh when a permission or a pack changes.
        _ = permissionRevision
        _ = packsRevision
        let hasModel = settings.settings.asrEngine == .apple || SpeechLanguage.allCases.contains { packs.isAvailable($0) }
        return Readiness(
            mic: MicrophonePermission.isGranted,
            camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            speechModel: hasModel
        )
    }

    var microphoneBlocked: Bool { AVAudioApplication.shared.recordPermission == .denied }

    var cameraBlocked: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    func refreshPermissions() {
        permissionRevision += 1
    }

    /// True when the microphone can be used now. A refusal for good can only be undone in the system Settings.
    func ensureMicrophone() async -> Bool {
        if MicrophonePermission.isGranted { return true }
        if microphoneBlocked {
            showToast(L10n.text("main_mic_blocked"))
            openSystemSettings()
            return false
        }
        let granted = await MicrophonePermission.request()
        refreshPermissions()
        if !granted { showToast(L10n.text("main_mic_blocked")) }
        return granted
    }

    /// Camera and microphone together: the camera mode records with sound.
    func ensureCamera() async -> Bool {
        if CameraPermission.isGranted { return true }
        if cameraBlocked || microphoneBlocked {
            showToast(L10n.text("ios_app_camera_blocked"))
            openSystemSettings()
            return false
        }
        let granted = await CameraPermission.request()
        refreshPermissions()
        if !granted { showToast(L10n.text("ios_app_camera_blocked")) }
        return granted
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Navigation

    func openScript(_ id: String) {
        guard library.select(id) else { return }
        router.path = [.script(id)]
    }

    // MARK: - Scene

    func sceneBecameActive() async {
        refreshPermissions()
        // Rehearsal stops with the app going to the background (below); listen again when it comes back.
        if router.showRehearsal, session.state.mode == .idle, MicrophonePermission.isGranted {
            session.start(mode: .rehearsal, audio: MicrophoneAudioSource())
        }
        consumePendingRoute()
        await importInbox()
    }

    func sceneWentToBackground() {
        if router.showRehearsal { session.stop() }
    }

    // MARK: - Deep links

    /// `suflyor://record?script=<id>`, `suflyor://pip?script=<id>`, `suflyor://import`, or a file opened with the app.
    func handle(url: URL) {
        if url.isFileURL {
            Task { await importFiles([url]) }
            return
        }
        guard url.scheme?.lowercased() == AppConstants.urlScheme else { return }
        let script = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "script" }?.value
        switch url.host?.lowercased() {
        case "record":
            showScriptForLink(script)
            Task { await startCamera() }
        case "pip":
            showScriptForLink(script)
            openPictureInPictureSheet()
        case "import":
            Task { await importInbox() }
        default:
            Journal.shared.warning("Unknown link: \(url.host ?? "")")
        }
    }

    /// An intent left a link while the app was not in the foreground.
    func consumePendingRoute() {
        if let url = PendingRoute.take() { handle(url: url) }
    }

    private func showScriptForLink(_ id: String?) {
        if let id, id != library.currentID { library.select(id) }
        if let current = library.currentID {
            router.path = [.script(current)]
        }
    }
}
