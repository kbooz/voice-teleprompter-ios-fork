import SwiftUI

/// Settings > About > Licenses: Suflyor's GPL-3.0 text and the third-party notices, bundled from the repository files.
struct LicensesView: View {
    var body: some View {
        List {
            NavigationLink(L10n.text("ios_app_licenses_gpl")) {
                LicenseTextView(title: L10n.text("ios_app_licenses_gpl"), resource: "LICENSE", fallback: "")
            }
            NavigationLink(L10n.text("ios_app_licenses_third_party")) {
                LicenseTextView(
                    title: L10n.text("ios_app_licenses_third_party"),
                    resource: "THIRD_PARTY_NOTICES.md",
                    fallback: ""
                )
            }
            NavigationLink(L10n.text("ios_app_licenses_ios")) {
                LicenseTextView(title: L10n.text("ios_app_licenses_ios"), resource: nil, fallback: Self.iosComponents)
            }
        }
        .navigationTitle(L10n.text("ios_app_licenses_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What only the iOS build adds. Names and licenses are not translated.
    private static let iosComponents = """
    ZIPFoundation (MIT): reads and writes zip files for DOCX/ODT import, backups and speech packs.
    https://github.com/weichsel/ZIPFoundation

    sherpa-onnx (Apache-2.0) and ONNX Runtime (MIT): on-device streaming speech recognition.
    https://github.com/k2-fsa/sherpa-onnx

    The speech models are the same as in the Android app; see the third-party components.
    """
}

private struct LicenseTextView: View {
    let title: String
    /// A file in the app bundle (added by project.yml), or nil to show `fallback`.
    let resource: String?
    let fallback: String
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let resource else {
                text = fallback
                return
            }
            if let url = Bundle.main.url(forResource: resource, withExtension: nil),
               let contents = try? String(contentsOf: url, encoding: .utf8) {
                text = contents
            } else {
                text = fallback
            }
        }
    }
}

/// What the app does with data: nothing leaves the phone.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(["ios_app_privacy_1", "ios_app_privacy_2", "ios_app_privacy_3", "ios_app_privacy_4"], id: \.self) { key in
                    Text(L10n.text(key))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(L10n.text("ios_app_privacy_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
