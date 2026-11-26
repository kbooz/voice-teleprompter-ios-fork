import AppIntents
import Foundation
import SuflyorDomain

// Compiled into the app and into the Controls extension: Shortcuts and the Action button find these intents in the
// app, Control Center runs the same types from the widget. Both only leave a `suflyor://` link for the app
// (see PendingRoute) and bring it to the front.

/// Texts of the intents and controls. In the app they come from the String Catalog (keys in ios-strings/app.json),
/// in the extension from its own Localizable.strings; the default value is the English text.
enum IntentText {
    static let recordTitle = LocalizedStringResource("ios_intent_record_title", defaultValue: "Record with teleprompter")
    static let recordDescription = LocalizedStringResource(
        "ios_intent_record_description",
        defaultValue: "Opens Suflyor on the camera with the current script."
    )
    static let recordShort = LocalizedStringResource("ios_intent_record_short", defaultValue: "Record")
    static let pipTitle = LocalizedStringResource("ios_intent_pip_title", defaultValue: "Show the script over another app")
    static let pipDescription = LocalizedStringResource(
        "ios_intent_pip_description",
        defaultValue: "Opens Suflyor to start the floating window over Instagram, TikTok or the Camera."
    )
    static let pipShort = LocalizedStringResource("ios_intent_pip_short", defaultValue: "Float over an app")
}

// The metadata extractor of the App Intents build step reads `title` and `description` from the source, so they
// are literals here and not references to IntentText (the texts above are repeated on purpose).
struct StartRecordingIntent: AppIntent {
    static let title = LocalizedStringResource("ios_intent_record_title", defaultValue: "Record with teleprompter")
    static let description = IntentDescription(
        LocalizedStringResource(
            "ios_intent_record_description",
            defaultValue: "Opens Suflyor on the camera with the current script."
        )
    )
    // VERIFY: still honoured on iOS 26 (the newer `supportedModes` may replace it).
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingRoute.leave(URL(string: "\(AppConstants.urlScheme)://record")!)
        return .result()
    }
}

struct StartPictureInPictureIntent: AppIntent {
    static let title = LocalizedStringResource("ios_intent_pip_title", defaultValue: "Show the script over another app")
    static let description = IntentDescription(
        LocalizedStringResource(
            "ios_intent_pip_description",
            defaultValue: "Opens Suflyor to start the floating window over Instagram, TikTok or the Camera."
        )
    )
    // VERIFY: see StartRecordingIntent.
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingRoute.leave(URL(string: "\(AppConstants.urlScheme)://pip")!)
        return .result()
    }
}
