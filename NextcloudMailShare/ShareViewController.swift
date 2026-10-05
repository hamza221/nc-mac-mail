// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import OSLog
import UniformTypeIdentifiers

/// The Share extension: whatever was shared — files, a web page's URL, selected text — is
/// copied into the app group's inbox as one item (`SharedInboxDrop`), and the app is asked
/// to open `ncmail://shared/<item id>`, which becomes `ComposeRequest.shared(inboxItemId:)`.
///
/// There is no UI: the composer is the UI. The extension never sees an account, a password
/// or the mirror, and has no network entitlement.
final class ShareViewController: NSViewController {
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "share")

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handOff() }
    }

    private func handOff() async {
        guard let context = extensionContext else { return }
        guard let inbox = SharedInboxDrop.inboxURL else {
            Self.logger.error("no app group container")
            context.cancelRequest(withError: CocoaError(.fileNoSuchFile))
            return
        }
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(SharedInboxDrop.newItemId(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var texts: [String] = []
        var urls: [URL] = []
        var files: [SharedInboxDrop.SharedFile] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
            for provider in item.attachments ?? [] {
                switch await Self.load(provider, staging: staging) {
                case .file(let file): files.append(file)
                case .url(let url): urls.append(url)
                case .text(let text): texts.append(text)
                case nil: continue
                }
            }
        }
        do {
            let itemId = try SharedInboxDrop.write(
                subject: items.first?.attributedTitle?.string,
                text: texts.isEmpty ? nil : texts.joined(separator: "\n\n"),
                urls: urls,
                files: files,
                inbox: inbox
            )
            Self.logger.info("shared item written with \(files.count, privacy: .public) files")
            if let link = SystemLink.shared(inboxItemId: itemId).url {
                NSWorkspace.shared.open(link)
            }
            context.completeRequest(returningItems: nil)
        } catch {
            Self.logger.error("shared item not written: \(String(describing: error), privacy: .public)")
            context.cancelRequest(withError: error)
        }
    }

    private enum Loaded {
        case file(SharedInboxDrop.SharedFile)
        case url(URL)
        case text(String)
    }

    /// A file first (a file URL is also a URL), then a web URL, then text, then any other
    /// data the provider can write to a file.
    private static func load(_ provider: NSItemProvider, staging: URL) async -> Loaded? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            let url = await loadObject(URL.self, from: provider), url.isFileURL
        {
            return copy(url, name: provider.suggestedName, to: staging).map(Loaded.file)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
            let url = await loadObject(URL.self, from: provider)
        {
            return .url(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
            let text = await loadObject(String.self, from: provider)
        {
            return .text(text)
        }
        guard
            let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .data) ?? false
            })
        else { return nil }
        let name = provider.suggestedName
        let copied: URL? = await withCheckedContinuation { continuation in
            // The provider deletes its file when this closure returns: copy inside it.
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let target = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(name ?? url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let copied else { return nil }
        return .file(
            SharedInboxDrop.SharedFile(
                source: copied, name: copied.lastPathComponent, mime: UTType(type)?.preferredMIMEType))
    }

    private static func loadObject<T: _ObjectiveCBridgeable & Sendable>(
        _ type: T.Type, from provider: NSItemProvider
    ) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    /// A shared file URL, read under the security scope the share sheet granted.
    private static func copy(_ url: URL, name: String?, to staging: URL) -> SharedInboxDrop.SharedFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileName = url.lastPathComponent
        let target = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            logger.error("shared file unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
        return SharedInboxDrop.SharedFile(
            source: target, name: name ?? fileName,
            mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
    }
}
