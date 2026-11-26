import AppIntents
import SuflyorDomain
import SwiftUI
import WidgetKit

@main
struct SuflyorControlsBundle: WidgetBundle {
    var body: some Widget {
        RecordControl()
        PictureInPictureControl()
    }
}

/// Control Center, Lock Screen and Action button: "Record with teleprompter".
struct RecordControl: ControlWidget {
    static let kind = "\(AppConstants.bundleIdPrefix).control.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            // VERIFY: ControlWidgetButton(action:label:) builds with this closure on the iOS 26 SDK.
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label {
                    Text(IntentText.recordShort)
                } icon: {
                    Image(systemName: "video.fill")
                }
            }
        }
        .displayName(IntentText.recordTitle)
        .description(IntentText.recordDescription)
    }
}

/// The floating window over another app (experimental).
struct PictureInPictureControl: ControlWidget {
    static let kind = "\(AppConstants.bundleIdPrefix).control.pip"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartPictureInPictureIntent()) {
                Label {
                    Text(IntentText.pipShort)
                } icon: {
                    Image(systemName: "pip")
                }
            }
        }
        .displayName(IntentText.pipTitle)
        .description(IntentText.pipDescription)
    }
}
