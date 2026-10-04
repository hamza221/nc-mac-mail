// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Synchronization
import Testing

@testable import NextcloudMail

@Suite("Widget snapshot (ADR-0071)")
struct WidgetSnapshotTests {
    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ws42-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    /// The rows the app's two inbox observations deliver, from a seeded mirror: the same
    /// queries `SystemIntegration` observes, read once.
    private static func inboxLists(
        _ fixture: SystemFixture
    ) async throws -> (important: [MessageRow], unread: [MessageRow]) {
        let important = try await fixture.store.messages(
            query: MessageListQuery(mailboxIds: [fixture.inboxId], isImportant: true), view: .flat, order: .newest,
            range: 0..<WidgetSnapshot.cap)
        let observation = fixture.store.observeSearchRows(
            SearchQuery(text: "", scope: .mailbox(fixture.inboxId), flags: SearchQuery.FlagFilter(unreadOnly: true)),
            range: 0..<WidgetSnapshot.cap)
        var unread: [MessageRow] = []
        for try await rows in observation {
            unread = rows
            break
        }
        return (important, unread)
    }

    @Test func theSnapshotIsCappedPrivateAndHoldsOnlySubjectsAndSenders() async throws {
        var fixture = try await SystemFixture.make()
        for remoteId in Int64(1)...12 {
            try await fixture.message(
                remoteId: remoteId, subject: "Subject \(remoteId)", sentAt: 1_790_000_000 + remoteId,
                isSeen: remoteId % 3 == 0, isImportant: remoteId % 2 == 0, sender: "Sender \(remoteId)")
        }
        // Not an inbox: never in the widget.
        try await fixture.message(remoteId: 99, mailboxId: fixture.archiveId, subject: "Archived", isImportant: true)

        let file = Self.temporaryFile()
        let reloads = ReloadCounter()
        let writer = WidgetSnapshotWriter(fileURL: file, reload: { reloads.increment() })
        let lists = try await Self.inboxLists(fixture)
        #expect(await writer.update(important: lists.important, unread: lists.unread))

        let snapshot = try #require(WidgetSnapshot.read(from: file))
        #expect(snapshot.important.count == 6)  // 2, 4, … 12
        #expect(snapshot.important.map(\.subject).first == "Subject 12")
        #expect(snapshot.unread.count == WidgetSnapshot.cap)
        #expect(snapshot.unread.allSatisfy { $0.isUnread })
        #expect(snapshot.unread.map(\.subject) == [11, 10, 8, 7, 5, 4, 2].map { "Subject \($0)" })
        #expect(!snapshot.important.contains { $0.subject == "Archived" })
        #expect(reloads.count == 1)

        // Private: owner read/write only.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Subjects and senders, ids and dates; no address, preview or body.
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(!json.contains("alice@example.invalid"))
        #expect(!json.contains("Preview"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let first = try #require((object?["unread"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["id", "subject", "sender", "sentAt", "isUnread"])
    }

    @Test func anUnchangedMirrorDoesNotRewriteOrReload() async throws {
        var fixture = try await SystemFixture.make()
        try await fixture.message(remoteId: 1, subject: "One", isImportant: true)
        let file = Self.temporaryFile()
        let reloads = ReloadCounter()
        let writer = WidgetSnapshotWriter(fileURL: file, reload: { reloads.increment() })
        var lists = try await Self.inboxLists(fixture)
        #expect(await writer.update(important: lists.important, unread: lists.unread))
        #expect(!(await writer.update(important: lists.important, unread: lists.unread)))
        #expect(reloads.count == 1)

        // A relaunch reads what is there and does not rewrite it either.
        let relaunched = WidgetSnapshotWriter(fileURL: file, reload: { reloads.increment() })
        #expect(!(await relaunched.update(important: lists.important, unread: lists.unread)))

        // Marking it read changes the unread list: one write, one reload.
        try await fixture.message(remoteId: 1, subject: "One", isSeen: true, isImportant: true)
        lists = try await Self.inboxLists(fixture)
        #expect(await relaunched.update(important: lists.important, unread: lists.unread))
        #expect(reloads.count == 2)
        #expect(WidgetSnapshot.read(from: file)?.unread.isEmpty == true)
    }

    @Test func theModelCapsWhateverItIsGiven() {
        let items = (0..<20).map {
            WidgetSnapshot.Item(id: Int64($0), subject: "S", sender: "A", sentAt: 0, isUnread: true)
        }
        let snapshot = WidgetSnapshot(writtenAt: 0, important: items, unread: items)
        #expect(snapshot.important.count == 7)
        #expect(snapshot.unread.count == 7)
    }
}

private nonisolated final class ReloadCounter: Sendable {
    private let value = Mutex(0)

    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
