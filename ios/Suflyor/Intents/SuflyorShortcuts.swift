import AppIntents

/// What shows up in Shortcuts, Spotlight and the Action button settings without any setup.
struct SuflyorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // VERIFY(user): phrases are English only; localize them with an AppShortcuts.xcstrings if wanted.
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Start \(.applicationName) teleprompter",
            ],
            shortTitle: LocalizedStringResource("ios_intent_record_short", defaultValue: "Record"),
            systemImageName: "video.fill"
        )
        AppShortcut(
            intent: StartPictureInPictureIntent(),
            phrases: [
                "Float \(.applicationName) over an app",
            ],
            shortTitle: LocalizedStringResource("ios_intent_pip_short", defaultValue: "Float over an app"),
            systemImageName: "pip"
        )
    }
}
