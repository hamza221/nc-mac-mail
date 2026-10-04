// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// `widget-snapshot.json`: everything the widgets know (ADR-0071).
///
/// The app writes it (`WidgetSnapshotWriter`); the widget extension only decodes it. It
/// holds subjects and senders and the local id a tap opens — no address, no preview, no
/// body — and never more than ``cap`` items per list.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    nonisolated struct Item: Codable, Equatable, Sendable, Identifiable {
        /// Local `message.id`; the widget's link is `ncmail://message/<id>`.
        var id: Int64
        var subject: String
        /// The sender's display name, else their address — whichever the list row shows.
        var sender: String
        /// Unix seconds.
        var sentAt: Int64
        var isUnread: Bool

        init(id: Int64, subject: String, sender: String, sentAt: Int64, isUnread: Bool) {
            self.id = id
            self.subject = subject
            self.sender = sender
            self.sentAt = sentAt
            self.isUnread = isUnread
        }
    }

    static let fileName = "widget-snapshot.json"
    /// ADR-0071: at most seven Important and seven Unread inbox items.
    static let cap = 7
    static let currentVersion = 1

    var version: Int
    /// Unix seconds; not part of what decides whether a write is needed.
    var writtenAt: Int64
    var important: [Item]
    var unread: [Item]

    /// Caps both lists, so no caller can write more than ADR-0071 allows.
    init(writtenAt: Int64, important: [Item], unread: [Item]) {
        version = Self.currentVersion
        self.writtenAt = writtenAt
        self.important = Array(important.prefix(Self.cap))
        self.unread = Array(unread.prefix(Self.cap))
    }

    static let empty = WidgetSnapshot(writtenAt: 0, important: [], unread: [])

    /// Same lists, whenever written.
    func hasSameItems(as other: WidgetSnapshot) -> Bool {
        important == other.important && unread == other.unread
    }

    /// `<container>/widget-snapshot.json`.
    static func url(in container: URL) -> URL {
        container.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Nil when there is no file yet or it is not one this version reads.
    static func read(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
            snapshot.version == currentVersion
        else { return nil }
        return snapshot
    }

    /// Atomically, owner-read/write only (0600): the file holds subjects and senders, and
    /// nothing but this user's own processes has any business reading it.
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
