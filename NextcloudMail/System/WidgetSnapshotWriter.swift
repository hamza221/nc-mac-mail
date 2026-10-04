// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import OSLog

/// Writes `widget-snapshot.json` into the app group and asks WidgetKit to reload (ADR-0071).
///
/// Fed by the inbox observations in `SystemIntegration`: every value is a sync pass (or a
/// local triage write) that touched inbox rows. It writes only when the lists the widgets
/// draw actually changed — a flag the widgets do not show changes nothing — so an idle
/// mirror never wakes WidgetKit.
actor WidgetSnapshotWriter {
    private let fileURL: URL
    private let reload: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private var last: WidgetSnapshot?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "widgets")

    /// - Parameter reload: `WidgetCenter.shared.reloadAllTimelines()` in the app.
    init(
        fileURL: URL,
        reload: @escaping @Sendable () -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.reload = reload
        self.now = now
        // What a previous launch wrote, so an unchanged mirror does not rewrite it.
        last = WidgetSnapshot.read(from: fileURL)
    }

    /// - Parameters:
    ///   - important: the inboxes' Important rows, newest first.
    ///   - unread: the inboxes' unread rows, in any order; sorted here.
    /// - Returns: whether the file was written.
    @discardableResult
    func update(important: [MessageRow], unread: [MessageRow]) -> Bool {
        let snapshot = Self.snapshot(important: important, unread: unread, at: now())
        if let last, last.hasSameItems(as: snapshot) { return false }
        do {
            try snapshot.write(to: fileURL)
            last = snapshot
            reload()
            return true
        } catch {
            Self.logger.error("widget snapshot not written: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    nonisolated static func snapshot(important: [MessageRow], unread: [MessageRow], at date: Date) -> WidgetSnapshot {
        let newestFirst: (MessageRow, MessageRow) -> Bool = { ($0.sentAt, $0.id) > ($1.sentAt, $1.id) }
        return WidgetSnapshot(
            writtenAt: Int64(date.timeIntervalSince1970),
            important: important.sorted(by: newestFirst).map(item),
            unread: unread.filter { !$0.isSeen }.sorted(by: newestFirst).map(item)
        )
    }

    private nonisolated static func item(_ row: MessageRow) -> WidgetSnapshot.Item {
        let subject = row.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WidgetSnapshot.Item(
            id: row.id,
            subject: subject.isEmpty ? String(localized: "No subject") : subject,
            sender: row.senderName ?? row.senderEmail ?? "",
            sentAt: row.sentAt,
            isUnread: !row.isSeen
        )
    }
}
