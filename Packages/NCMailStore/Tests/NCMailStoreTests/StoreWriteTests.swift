// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Writes and deletes")
struct StoreWriteTests {
    /// Every table, counted. A cascade that misses one leaves rows nothing can reach and
    /// nothing will ever delete, and the only way to know is to count them all.
    @Test func deletingAnAccountLeavesNothingBehind() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Sent")], accountId: 1)
        try await store.upsert(
            envelopes: (1...5).map {
                Seed.envelope(
                    id: $0,
                    mailboxId: $0 % 2 == 0 ? 11 : 10,
                    sentAt: 100 + $0,
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "a@example.invalid", label: "A"),
                        EnvelopeAddress(kind: .to, email: "b@example.invalid", label: "B"),
                    ]
                )
            }
        )
        for id in Int64(1)...5 {
            try await store.upsert(
                body: MessageBodyWrite(
                    fetchedAt: 1,
                    plainBody: "text \(id)",
                    attachments: [AttachmentWrite(attachmentId: "2", fileName: "a.pdf")]
                ),
                for: id
            )
        }
        try await store.write { db in
            try TagRecord(id: 1, imapLabel: "$label1", displayName: "Important").insert(db)
            try MessageTagRecord(messageId: 1, tagId: 1).insert(db)
            var operation = PendingOperationRecord(
                kind: "setFlags",
                accountId: 1,
                messageId: 1,
                payloadJSON: "{\"seen\":true}",
                createdAt: 1,
                baseSyncedAt: 1
            )
            try operation.insert(db)
        }

        try await store.deleteAccount(id: 1)

        let counts = try await store.read { db -> [String: Int] in
            var counts: [String: Int] = [:]
            let tables = [
                "account", "mailbox", "message", "messageAddress", "messageBody", "attachment",
                "messageTag", "pendingOperation", "messageSearch", "tag",
            ]
            for table in tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
            return counts
        }

        for (table, count) in counts.sorted(by: { $0.key < $1.key }) where table != "tag" {
            #expect(count == 0, "\(table) still has \(count) rows after the account was deleted")
        }
        // `tag` is a per-server list of IMAP keywords, not per-account data, so it stays.
        #expect(counts["tag"] == 1)
    }

    /// The reason ``EnvelopeWrite`` is a different type from ``MessageRecord``. A flag change
    /// arriving from sync must not tell the mirror it has lost a body it already downloaded.
    @Test func reSyncingAnEnvelopeKeepsTheBodyState() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100)])
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 200, plainBody: "kept"), for: 1)
        #expect(try await store.message(id: 1)?.bodyState == .present)

        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100, isSeen: true)])

        let message = try await store.message(id: 1)
        #expect(message?.bodyState == .present)
        #expect(message?.isSeen == true)
        #expect(try await store.body(messageId: 1)?.body.plainBody == "kept")
    }

    /// The same argument one level up: a folder refresh must not roll the mirror's own progress
    /// back to zero.
    @Test func refreshingAMailboxKeepsItsMirrorProgress() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.setEnvelopeCursor(1_700_000_000, complete: true, mailboxId: 10, lastSyncAt: 5)

        try await store.upsert(mailboxes: [Seed.mailbox(id: 10, name: "INBOX")], accountId: 1)

        let mailbox = try await store.mailboxes(accountId: 1).first
        #expect(mailbox?.envelopeCursor == 1_700_000_000)
        #expect(mailbox?.envelopesComplete == true)
        #expect(mailbox?.isMirrored == true)
    }

    @Test func addressesAreRewrittenRatherThanMerged() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    id: 1,
                    sentAt: 100,
                    addresses: [
                        EnvelopeAddress(kind: .to, email: "one@example.invalid"),
                        EnvelopeAddress(kind: .to, email: "two@example.invalid"),
                    ]
                )
            ]
        )
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    id: 1,
                    sentAt: 100,
                    addresses: [EnvelopeAddress(kind: .to, email: "one@example.invalid")]
                )
            ]
        )
        let addresses = try await store.read { db in
            try MessageAddressRecord.fetchAll(db, sql: "SELECT * FROM messageAddress ORDER BY position")
        }
        #expect(addresses.map(\.email) == ["one@example.invalid"])
        #expect(addresses.map(\.position) == [0])
    }

    @Test func aBodyIsStoredWithItsAttachmentsAndAMeasuredSize() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100)])
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 900,
                hasHtmlBody: true,
                html: "<p>hello</p>",
                plainBody: "hello",
                attachments: [
                    AttachmentWrite(
                        attachmentId: "2",
                        isInline: true,
                        fileName: "logo.png",
                        cid: "cid1",
                        isImage: true
                    )
                ]
            ),
            for: 1
        )

        let stored = try await store.body(messageId: 1)
        #expect(stored?.body.byteSize == Int64("<p>hello</p>".utf8.count + "hello".utf8.count))
        #expect(stored?.attachments.map(\.attachmentId) == ["2"])
        #expect(stored?.attachments.first?.data == nil)
    }

    @Test func anInlineImageIsKeptOnceFetched() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100)])
        try await store.upsert(
            body: MessageBodyWrite(fetchedAt: 1, attachments: [AttachmentWrite(attachmentId: "2", isInline: true)]),
            for: 1
        )
        try await store.storeInlineAttachment(
            messageId: 1,
            attachmentId: "2",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            fetchedAt: 42
        )
        let stored = try await store.body(messageId: 1)
        #expect(stored?.attachments.first?.data?.count == 4)
        #expect(stored?.attachments.first?.fetchedAt == 42)
    }

    @Test func progressIsCountedFromTheRows() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Sent")], accountId: 1)
        try await store.upsert(envelopes: (1...10).map { Seed.envelope(id: $0, sentAt: 100 + $0) })
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 1, plainBody: "x"), for: 1)
        try await store.setBodyState(.failed, messageIds: [2])
        try await store.setEnvelopeCursor(nil, complete: true, mailboxId: 10, lastSyncAt: 1)

        let progress = try await store.mirrorProgress(accountId: 1)
        #expect(progress.totalMessages == 10)
        #expect(progress.bodiesPresent == 1)
        #expect(progress.bodiesFailed == 1)
        #expect(progress.mailboxesRemaining == 1)
        #expect(progress.isComplete == false)
    }

    @Test func theStorageFootprintAddsUpWhatIsActuallyStored() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...3).map { Seed.envelope(id: $0, sentAt: 100 + $0) })
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1,
                plainBody: "0123456789",
                attachments: [AttachmentWrite(attachmentId: "2")]
            ),
            for: 1
        )
        try await store.storeInlineAttachment(messageId: 1, attachmentId: "2", data: Data(count: 64), fetchedAt: 1)

        let footprint = try await store.storageFootprint(accountId: 1)
        #expect(footprint.messageCount == 3)
        #expect(footprint.bodyCount == 1)
        #expect(footprint.bodyBytes == 10)
        #expect(footprint.attachmentBytes == 64)
    }

    @Test func metaValuesRoundTripAndCanBeRemoved() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue("paused", forKey: "backfill.state")
        #expect(try await store.metaValue(forKey: "backfill.state") == "paused")
        try await store.setMetaValue("running", forKey: "backfill.state")
        #expect(try await store.metaValue(forKey: "backfill.state") == "running")
        try await store.setMetaValue(nil, forKey: "backfill.state")
        #expect(try await store.metaValue(forKey: "backfill.state") == nil)
    }

    @Test func everyRecordRoundTrips() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100)])

        try await store.write { db in
            try AvatarRecord(email: "a@example.invalid", data: Data([1, 2]), mime: "image/png", fetchedAt: 9)
                .insert(db)
            try TagRecord(id: 1, imapLabel: "$seen", displayName: "Seen", color: "#ff0000").insert(db)
            var operation = PendingOperationRecord(
                kind: "move",
                accountId: 1,
                messageId: 1,
                mailboxId: 10,
                payloadJSON: "{\"destFolderId\":11}",
                createdAt: 3,
                baseSyncedAt: 100
            )
            try operation.insert(db)
            #expect(operation.id == 1)
        }

        try await store.read { db in
            #expect(try AvatarRecord.fetchOne(db, sql: "SELECT * FROM avatar")?.mime == "image/png")
            #expect(try TagRecord.fetchOne(db, sql: "SELECT * FROM tag")?.color == "#ff0000")
            let operation = try PendingOperationRecord.fetchOne(db, sql: "SELECT * FROM pendingOperation")
            #expect(operation?.state == .pending)
            #expect(operation?.attempts == 0)
            let message = try MessageRecord.fetchOne(db, sql: "SELECT * FROM message")
            #expect(message?.bodyState == .missing)
            #expect(message?.mailboxId == 10)
            let account = try AccountRecord.fetchOne(db, sql: "SELECT * FROM account")
            #expect(account?.mirrorState == .idle)
            // Null on the live server this was checked against, and nothing may assume otherwise.
            #expect(account?.archiveMailboxId == nil)
        }
    }

    @Test func theMirrorStateIsRecordedWithoutClobberingTheLastSync() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.setMirrorState(.envelopes, accountId: 1, lastSyncAt: 777)
        try await store.setMirrorState(.complete, accountId: 1)

        let account = try await store.accounts().first
        #expect(account?.mirrorState == .complete)
        #expect(account?.lastSyncAt == 777)
    }

    @Test func aFailedSyncIsCountedRatherThanThrown() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.recordSyncFailure(mailboxId: 10, message: "428 Precondition Required")
        try await store.recordSyncFailure(mailboxId: 10, message: "428 Precondition Required")

        let mailbox = try await store.mailboxes(accountId: 1).first
        #expect(mailbox?.syncFailureCount == 2)
        #expect(mailbox?.lastSyncError == "428 Precondition Required")
    }
}
