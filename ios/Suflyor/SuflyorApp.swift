import SwiftUI

@main
struct SuflyorApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.settings)
                .environment(env.library)
                .environment(env.session)
                .environment(env.router)
                // The UI is always dark, as on Android.
                .preferredColorScheme(.dark)
        }
    }
}
