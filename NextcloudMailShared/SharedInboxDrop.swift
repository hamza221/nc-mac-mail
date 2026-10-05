// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The writing half of the Share extension hand-off; `SharedInbox` (WS-27) is the reading
/// half and its doc comment is the format's contract:
///
/// ```
/// <inbox>/<itemId>/item.json
/// <inbox>/<itemId>/<file name>…
/// ```
///
/// Compiled into the extension, which writes, and into the app, whose tests prove that what
/// this writes is what `SharedInbox.take` reads (`ShareHandoffTests`).
nonisolated enum SharedInboxDrop {
    /// `item.json`, version 1 — the same keys `SharedInbox.Item` decodes.
    struct Manifest: Codable, Equatable, Sendable {
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
    }

    /// One shared file, already readable by this process.
    struct SharedFile: Sendable {
        var source: URL
        /// What the composer shows; defaults to the source's last path component.
        var name: String
        var mime: String?
    }

    /// `SharedInbox/` in the group container.
    static var inboxURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("SharedInbox", isDirectory: true)
    }

    /// The item directory's name: a single path component the reader accepts.
    static func newItemId() -> String { UUID().uuidString }

    /// Creates one item and returns its id.
    ///
    /// The files are copied first and `item.json` is written last, atomically, so an item
    /// the app can see is always complete. A failure removes the half-written directory.
    @discardableResult
    static func write(
        itemId: String = newItemId(),
        subject: String? = nil,
        text: String? = nil,
        urls: [URL] = [],
        files: [SharedFile] = [],
        inbox: URL,
        now: Date = Date()
    ) throws -> String {
        let directory = inbox.appendingPathComponent(itemId, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var entries: [Manifest.File] = []
            var used: Set<String> = []
            for file in files {
                let fileName = uniqueFileName(for: file.name, used: &used)
                try manager.copyItem(at: file.source, to: directory.appendingPathComponent(fileName))
                entries.append(Manifest.File(name: file.name, mime: file.mime, fileName: fileName))
            }
            let manifest = Manifest(
                version: 1,
                createdAt: Int64(now.timeIntervalSince1970),
                subject: subject,
                text: text,
                urls: urls.map(\.absoluteString),
                files: entries
            )
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent("item.json"), options: [.atomic])
            return itemId
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    /// Item ids with a complete `item.json`, oldest first: what the app opens on launch for
    /// a hand-off whose `ncmail://shared/` link never arrived.
    static func pendingItemIds(inbox: URL) -> [String] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return
            entries
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("item.json").path) }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (url.lastPathComponent, created)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// A name safe as one path component and unique within the item.
    private static func uniqueFileName(for name: String, used: inout Set<String>) -> String {
        var base = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if base.isEmpty || base == "." || base == ".." || base == "item.json" { base = "file" }
        var candidate = base
        var counter = 2
        while used.contains(candidate) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }
}
