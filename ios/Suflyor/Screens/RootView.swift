import SuflyorCamera
import SuflyorDomain
import SuflyorPrompter
import SwiftUI

/// Navigation, the full-screen prompter covers, deep links and the foreground work.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = env.router
        NavigationStack(path: $router.path) {
            LibraryView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .fullScreenCover(isPresented: $router.showCamera) {
            CameraScreen(store: env.session, settings: env.settings.wholeBinding, onClose: { env.closeCamera() })
        }
        .fullScreenCover(isPresented: $router.showRehearsal) {
            RehearsalScreen(store: env.session, settings: env.settings.wholeBinding, onClose: { env.closeRehearsal() })
        }
        .sheet(isPresented: $router.showPictureInPicture) {
            PictureInPictureSheet()
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: env.toastMessage)
        .onOpenURL { env.handle(url: $0) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await env.sceneBecameActive() }
            case .background: env.sceneWentToBackground()
            default: break
            }
        }
        // Cold start: the scene is already active, so nothing changes.
        .task { await env.sceneBecameActive() }
        .onReceive(NotificationCenter.default.publisher(for: PendingRoute.notification)) { _ in
            env.consumePendingRoute()
        }
        .onChange(of: library.saveError) { _, message in
            guard let message else { return }
            env.showToast(message)
            library.saveError = nil
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .script(let id):
            ScriptView(id: id)
        case .editor(let id):
            let document = id.flatMap { library.document(id: $0) }
            EditorView(
                id: id,
                initialTitle: document?.title ?? "",
                initialText: document?.toEditableText() ?? "",
                speechLanguage: document?.speechLanguage
            )
        case .settings:
            SettingsHomeView()
        case .settingsPage(let page):
            SettingsPageView(page: page)
        case .journal:
            JournalView()
        case .licenses:
            LicensesView()
        case .privacy:
            PrivacyView()
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = env.toastMessage {
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
                .allowsHitTesting(false)
        }
    }
}
