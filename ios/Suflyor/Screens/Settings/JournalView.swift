import SuflyorDomain
import SwiftUI
import UIKit

/// The in-app log (Android: `JournalScreen`). It never leaves the phone unless the user shares it.
struct JournalView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var lines: [String] = []

    var body: some View {
        let report = fullText
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.contains("[error]") ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.horizontal, 14)
            }
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .navigationTitle(L10n.text("journal_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = report
                    env.showToast(L10n.text("journal_toast_copied"))
                } label: {
                    Label(L10n.text("journal_cd_copy"), systemImage: "doc.on.doc")
                }
                ShareLink(item: report, subject: Text(L10n.text("journal_share_title"))) {
                    Label(L10n.text("journal_cd_share"), systemImage: "square.and.arrow.up")
                }
                Button {
                    Journal.shared.clear()
                    refresh()
                } label: {
                    Label(L10n.text("journal_cd_clear"), systemImage: "trash")
                }
            }
        }
        // The journal has no change notifications: look again every second while the screen is open.
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        let text = Journal.shared.exportText()
        let next = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if next != lines { lines = next }
    }

    /// The header is English like the journal lines under it: the text goes into bug reports.
    private var fullText: String {
        let device = UIDevice.current
        let settings = env.settings.settings
        return "Suflyor \(SettingsHomeView.appVersion), \(device.model), iOS \(device.systemVersion)\n"
            + "Engine \(settings.asrEngine.rawValue)\n\n"
            + Journal.shared.exportText()
    }
}
