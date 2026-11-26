import SuflyorDomain
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share extension: copies the shared text or document into `<App Group>/Inbox/<id>/` and says so. The app imports
/// the inbox when it comes to the foreground: an extension can't reliably open its host app, and importing needs
/// the whole parser stack, which doesn't belong in an extension's memory budget.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let host = UIHostingController(rootView: ShareStatusView(model: model) { [weak self] in
            self?.finish()
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let attachments = items.flatMap { item in
            (item.attachments ?? []).map {
                SharedAttachment(provider: $0, title: item.attributedContentText?.string ?? item.attributedTitle?.string)
            }
        }
        Task { @MainActor [self] in
            let saved = await InboxWriter.save(attachments)
            model.state = saved > 0 ? .saved : .failed
            if saved > 0 {
                // Long enough to read, short enough not to need a tap.
                try? await Task.sleep(for: .seconds(1.6))
                finish()
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State { case saving, saved, failed }
    var state: State = .saving
}

private struct ShareStatusView: View {
    let model: ShareModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .saving:
                ProgressView()
            case .saved:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text(ShareStrings.saved)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(ShareStrings.failed)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button(ShareStrings.close, action: close)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The extension has no String Catalog of its own: four short texts, chosen by the user's language list.
private enum ShareStrings {
    static var saved: String { pick(
        en: "Saved — open Suflyor to import",
        ptBR: "Salvo — abra o Suflyor para importar",
        ru: "Сохранено — откройте Suflyor, чтобы импортировать",
        tr: "Kaydedildi — içe aktarmak için Suflyor'u açın"
    ) }

    static var failed: String { pick(
        en: "Couldn't save this item",
        ptBR: "Não foi possível salvar este item",
        ru: "Не удалось сохранить",
        tr: "Bu öğe kaydedilemedi"
    ) }

    static var close: String { pick(en: "Close", ptBR: "Fechar", ru: "Закрыть", tr: "Kapat") }

    private static func pick(en: String, ptBR: String, ru: String, tr: String) -> String {
        let code = Locale.preferredLanguages.first ?? "en"
        if code.hasPrefix("pt") { return ptBR }
        if code.hasPrefix("ru") { return ru }
        if code.hasPrefix("tr") { return tr }
        return en
    }
}

/// One shared item. `NSItemProvider` isn't `Sendable` but is documented as safe to use from any thread; wrapping it
/// lets the copy run off the main actor without isolation errors.
private struct SharedAttachment: @unchecked Sendable {
    let provider: NSItemProvider
    let title: String?
}

/// Copies what was shared into the App Group inbox. One folder per item keeps the original file name.
/// Nonisolated on purpose: the system calls the item provider's handlers on its own queues.
private enum InboxWriter {
    /// Types the app can import, besides plain text (see the activation rule in Info.plist).
    private static let fileTypes: [UTType] = {
        var types: [UTType] = [.rtf, .html, .pdf, .zip, .plainText]
        for identifier in [
            "net.daringfireball.markdown",
            "org.openxmlformats.wordprocessingml.document",
            "org.oasis-open.opendocument.text",
        ] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    /// Returns how many items were saved.
    static func save(_ attachments: [SharedAttachment]) async -> Int {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)
        else { return 0 }
        let inbox = group.appendingPathComponent("Inbox", isDirectory: true)
        var saved = 0
        for attachment in attachments {
            if await save(attachment, inbox: inbox) { saved += 1 }
        }
        return saved
    }

    private static func save(_ attachment: SharedAttachment, inbox: URL) async -> Bool {
        let provider = attachment.provider
        let title = attachment.title
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A document or a text file: copy the file itself, named as it was.
            if let type = fileTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || !type.conforms(to: .plainText)
                if isFile {
                    try await copyFile(of: provider, as: type, into: folder)
                    return true
                }
                // Selected text (Notes, Safari, Messages): write it as a .txt named after its first line.
                if let text = try await loadText(of: provider), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let name = fileName(for: text, fallback: title)
                    try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    return true
                }
            }
            try? FileManager.default.removeItem(at: folder)
            return false
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
    }

    /// `loadFileRepresentation` hands over a temporary file that exists only inside the handler: copy it there.
    private static func copyFile(of provider: NSItemProvider, as type: UTType, into folder: URL) async throws {
        let suggested = provider.suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                var name = url.lastPathComponent
                // The suggested name has the title the user knows; keep the extension of the real file.
                if let suggested, !suggested.isEmpty {
                    let ext = url.pathExtension
                    let base = (suggested as NSString).deletingPathExtension
                    name = ext.isEmpty ? base : base + "." + ext
                }
                do {
                    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadText(of provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
            _ = provider.loadObject(ofClass: NSString.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (object as? NSString).map { $0 as String })
                }
            }
        }
    }

    /// The first non-empty line, cut to a file-name length and cleaned of path characters; the importer shows
    /// it as the script's title.
    private static func fileName(for text: String, fallback: String?) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        var base = firstLine ?? fallback ?? "Shared text"
        base = String(base.prefix(60))
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        base = base.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Shared text" : base) + ".txt"
    }
}
