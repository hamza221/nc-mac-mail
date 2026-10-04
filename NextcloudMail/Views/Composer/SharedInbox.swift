// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog

/// The hand-off between the Share extension (WS-42) and the composer:
/// `ComposeRequest.shared(inboxItemId:)` names a directory in the inbox this type reads.
///
/// The format, which WS-42's extension writes:
///
/// ```
/// <inbox>/<inboxItemId>/item.json
/// <inbox>/<inboxItemId>/<file name>…        (the shared files, copied in)
/// ```
///
/// `item.json` is ``SharedInbox/Item``: `version` (1), `createdAt` (unix seconds), and the
/// optional `subject`, `text`, `urls` and `files` (`name`, `mime`, `fileName` — the file's
/// name inside the item directory). `<inbox>` is `SharedInbox/` in the app-group
/// container ``appGroupIdentifier``, falling back to the app's own Application Support
/// while the app group does not exist yet (no entitlement before WS-42), so the path is
/// testable today. The composer takes an item exactly once: its files are moved into the
/// composer's attachment staging and the item directory is removed.
nonisolated enum SharedInbox {
    static var appGroupIdentifier: String { AppGroup.identifier }  // WS-42: team-prefixed (ADR-0100)

    struct Item: Codable, Equatable, Sendable {
        struct File: Codable, Equatable, Sendable {
            var name: String
            var mime: String?
            var fileName: String
        }

        var version: Int
        var createdAt: Int64
        var subject: String?
        var text: String?
        var urls: [String]
        var files: [File]

        init(
            version: Int = 1, createdAt: Int64, subject: String? = nil, text: String? = nil,
            urls: [String] = [], files: [File] = []
        ) {
            self.version = version
            self.createdAt = createdAt
            self.subject = subject
            self.text = text
            self.urls = urls
            self.files = files
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            createdAt = try container.decode(Int64.self, forKey: .createdAt)
            subject = try container.decodeIfPresent(String.self, forKey: .subject)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
            files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
        }
    }

    /// What the composer gets: the item's text and its files, already in staging.
    struct Taken: Sendable {
        struct StagedFile: Sendable {
            var name: String
            var mime: String?
            var size: Int64?
            var path: String
        }

        var subject: String?
        var text: String?
        var urls: [String]
        var stagedFiles: [StagedFile]
    }

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "composer")

    static var inboxURL: URL? {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return group.appendingPathComponent("SharedInbox", isDirectory: true)
        }
        return try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SharedInbox", isDirectory: true)
    }

    /// Reads, stages and removes one item. Nil when it does not exist or cannot be read.
    static func take(itemId: String, inbox: URL? = inboxURL) -> Taken? {
        // An id is a single path component; anything else is not ours to read.
        guard let inbox, !itemId.isEmpty, !itemId.contains("/"), itemId != "..", itemId != "." else { return nil }
        let directory = inbox.appendingPathComponent(itemId, isDirectory: true)
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("item.json"))
            let item = try JSONDecoder().decode(Item.self, from: data)
            guard item.version == 1 else { return nil }
            var staged: [Taken.StagedFile] = []
            for file in item.files {
                guard !file.fileName.contains("/") else { continue }
                let source = directory.appendingPathComponent(file.fileName)
                let target = try AttachmentStaging.stage(moving: source, name: file.name)
                staged.append(
                    Taken.StagedFile(
                        name: file.name, mime: file.mime, size: AttachmentStaging.size(of: target), path: target.path))
            }
            try? FileManager.default.removeItem(at: directory)
            return Taken(subject: item.subject, text: item.text, urls: item.urls, stagedFiles: staged)
        } catch {
            logger.error("shared item unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Where local attachments wait until the drafts engine uploads them: one directory per
/// file under Application Support, so two files with one name never collide.
nonisolated enum AttachmentStaging {
    static var root: URL {
        get throws {
            try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ComposerAttachments", isDirectory: true)
        }
    }

    static func stage(copying source: URL, name: String? = nil) throws -> URL {
        let target = try newLocation(name: name ?? source.lastPathComponent)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func stage(moving source: URL, name: String) throws -> URL {
        let target = try newLocation(name: name)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    static func stage(data: Data, name: String) throws -> URL {
        let target = try newLocation(name: name)
        try data.write(to: target, options: .atomic)
        return target
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Removes a staged file and its directory once its row is gone.
    static func discard(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let root = try? root, url.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func newLocation(name: String) throws -> URL {
        let directory = try root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
    }
}
