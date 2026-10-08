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
    ///
    /// `tag` is in the list now. It used to be excluded as "a per-server list of IMAP
    /// keywords", which was wrong twice over: a keyword belongs to an account server-side,
    /// and "per server" stopped meaning anything once two servers could share this file
    /// (ADR-0033). It has an `accountId` and cascades with everything else.
    @Test func deletingAnAccountLeavesNothingBehind() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Sent")], accountId: 1)
        try await store.upsert(
            envelopes: (1...5).map {
                Seed.envelope(
                    remoteId: $0,
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
            try TagRecord(id: 1, accountId: 1, remoteId: 1, imapLabel: "$label1", displayName: "Important")
                .insert(db)
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

        for (table, count) in counts.sorted(by: { $0.key < $1.key }) {
            #expect(count == 0, "\(table) still has \(count) rows after the account was deleted")
        }
    }

    /// `avatar` has no `accountId` and no foreign key, because one person's picture is shared
    /// by every account that hears from them (ADR-0033), so no cascade reaches it. Removing an
    /// account must still take the addresses only its mail named; the rows other accounts'
    /// mail still names stay.
    @Test func deletingAnAccountTakesTheAvatarsOnlyItsMailNamed() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let other = try #require(try await store.upsert(accounts: [Seed.account(remoteId: 2)]).first)
        let inbox = MailboxWrite(
            accountId: other.id,
            remoteId: 5,
            name: "INBOX",
            displayName: "INBOX",
            isSubscribed: true
        )
        let otherMailbox = try #require(try await store.upsert(mailboxes: [inbox], accountId: other.id).first)
        func message(_ remoteId: Int64, from email: String?, otherAccount: Bool = false) -> EnvelopeWrite {
            Seed.envelope(
                remoteId: remoteId,
                mailboxId: otherAccount ? otherMailbox.id : 10,
                accountId: otherAccount ? other.id : 1,
                sentAt: 100 + remoteId,
                addresses: email.map { [EnvelopeAddress(kind: .from, email: $0)] } ?? []
            )
        }
        try await store.upsert(
            envelopes: [
                message(1, from: "only-a@example.invalid"),
                message(2, from: "Shared@Example.invalid"),
                message(1, from: "only-b@example.invalid", otherAccount: true),
                message(2, from: "shared@example.invalid", otherAccount: true),
                // No sender leaves a NULL in the column the cleanup reads, and `NOT IN` a
                // list holding NULL is never true: one such row must not stop the cleanup.
                message(3, from: nil, otherAccount: true),
            ]
        )
        for email in ["only-a@example.invalid", "shared@example.invalid", "only-b@example.invalid"] {
            try await store.upsert(avatar: AvatarRecord(email: email, missing: true, fetchedAt: 1), accountId: other.id)
        }

        try await store.deleteAccount(id: 1)

        let remaining = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT email FROM avatar ORDER BY email")
        }
        #expect(remaining == ["only-b@example.invalid", "shared@example.invalid"])
    }

    /// The account's avatar fetcher stops after the account row is gone, not before, so an
    /// answer already in flight lands after the cleanup above. It must not bring the address
    /// back.
    @Test func anAvatarWrittenForADeletedAccountIsDropped() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.deleteAccount(id: 1)

        let late = AvatarRecord(email: "late@example.invalid", missing: true, fetchedAt: 1)
        try await store.upsert(avatar: late, accountId: 1)

        #expect(try await store.avatar(for: "late@example.invalid") == nil)
    }

    /// Signing a login out with its local copies removed takes its correspondents' and its
    /// contacts' pictures too, and keeps a photo another login's contact still names.
    @Test func deletingALoginTakesTheAvatarsNothingLeftNames() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1, sentAt: 101, addresses: [EnvelopeAddress(kind: .from, email: "sender@example.invalid")]
                )
            ]
        )
        let gone = try #require(try await store.ensureLogin(Seed.identity).id)
        let staying = try #require(
            try await store.ensureLogin(ServerIdentity(serverURL: "https://two.example.invalid/", loginName: "ada")).id
        )
        for (loginId, email) in [(gone, "friend@example.invalid"), (staying, "Kept@Example.invalid")] {
            let book = try #require(
                try await store.syncAddressBooks(
                    [AddressBookRecord(loginId: loginId, url: "/dav/books/\(loginId)/", displayName: "Personal")],
                    loginId: loginId
                ).first?.id
            )
            try await store.upsert(
                contact: ContactRecord(
                    addressBookId: book, href: "/dav/books/\(loginId)/a.vcf", vcard: "BEGIN:VCARD\nEND:VCARD",
                    syncedAt: 1),
                emails: [ContactEmailRecord(contactId: 0, position: 0, email: email)]
            )
        }
        for email in ["sender@example.invalid", "friend@example.invalid", "kept@example.invalid"] {
            try await store.upsert(avatar: AvatarRecord(email: email, data: Data([1]), isExternal: false, fetchedAt: 1))
        }

        try await store.deleteLogin(Seed.identity)

        let remaining = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT email FROM avatar ORDER BY email")
        }
        #expect(remaining == ["kept@example.invalid"])
    }

    /// The collision ADR-0033 exists for: two Nextcloud instances, each with an account 1,
    /// a mailbox 5 and a message 100.
    ///
    /// Before local ids, the second server's rows overwrote the first's — same primary key,
    /// `upsert`, no error, no warning. The live test instance has one account and cannot
    /// show this, so the two servers here are two `ServerIdentity` values and the same
    /// numbers written twice.
    @Test func twoServersWithTheSameNumericIdsDoNotCollide() async throws {
        let store = try MailStore.inMemory()
        let one = ServerIdentity(serverURL: "https://one.example.invalid/", loginName: "ada")
        let two = ServerIdentity(serverURL: "https://two.example.invalid/", loginName: "ada")

        var accountIds: [Int64] = []
        var messageIds: [Int64] = []
        for (identity, subject) in [(one, "from one"), (two, "from two")] {
            let accounts = try await store.upsert(
                accounts: [
                    AccountWrite(identity: identity, remoteId: 1, name: "Mail", emailAddress: "ada@example.invalid")
                ]
            )
            let account = try #require(accounts.first)
            accountIds.append(account.id)

            let mailboxes = try await store.upsert(
                mailboxes: [
                    MailboxWrite(
                        accountId: account.id,
                        remoteId: 5,
                        name: "INBOX",
                        displayName: "INBOX",
                        isSubscribed: true
                    )
                ],
                accountId: account.id
            )
            let mailbox = try #require(mailboxes.first)

            messageIds.append(
                contentsOf: try await store.upsert(
                    envelopes: [
                        Seed.envelope(
                            remoteId: 100,
                            mailboxId: mailbox.id,
                            accountId: account.id,
                            sentAt: 500,
                            subject: subject
                        )
                    ]
                )
            )
        }

        #expect(Set(accountIds).count == 2)
        #expect(Set(messageIds).count == 2)
        #expect(try await store.accounts().count == 2)
        #expect(try await store.accounts(identity: one).count == 1)
        #expect(try await store.accounts(identity: two).count == 1)

        // Both messages are still here, each under its own account, with its own subject.
        let firstId = try #require(messageIds.first)
        let secondId = try #require(messageIds.last)
        let first = try #require(try await store.message(id: firstId))
        let second = try #require(try await store.message(id: secondId))
        #expect(first.remoteId == 100)
        #expect(second.remoteId == 100)
        #expect(first.subject == "from one")
        #expect(second.subject == "from two")
        #expect(first.accountId != second.accountId)

        // And deleting one server's account leaves the other's untouched.
        let firstAccountId = try #require(accountIds.first)
        try await store.deleteAccount(id: firstAccountId)
        #expect(try await store.accounts().count == 1)
        #expect(try await store.message(id: second.id) != nil)
    }

    /// The reason ``EnvelopeWrite`` is a different type from ``MessageRecord``. A flag change
    /// arriving from sync must not tell the mirror it has lost a body it already downloaded.
    @Test func reSyncingAnEnvelopeKeepsTheBodyState() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 200, plainBody: "kept"), for: 1)
        #expect(try await store.message(id: 1)?.bodyState == .present)

        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, isSeen: true)])

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
                    remoteId: 1,
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
                    remoteId: 1,
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
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])
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
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])
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
        try await store.upsert(envelopes: (1...10).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })
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
        try await store.upsert(envelopes: (1...3).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })
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
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])

        try await store.write { db in
            try AvatarRecord(email: "a@example.invalid", data: Data([1, 2]), mime: "image/png", fetchedAt: 9)
                .insert(db)
            try TagRecord(id: 1, accountId: 1, remoteId: 1, imapLabel: "$seen", displayName: "Seen", color: "#ff0000")
                .insert(db)
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

    @Test func syncFailuresAreObservedAndASuccessClearsThem() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        var iterator = store.observeMailboxSyncFailures(accountId: 1).makeAsyncIterator()
        #expect(try await iterator.next() == [])

        try await store.recordSyncFailure(mailboxId: 10, message: "unauthorized")
        #expect(
            try await iterator.next()
                == [MailboxSyncFailure(id: 10, syncFailureCount: 1, lastSyncError: "unauthorized")]
        )
        try await store.setEnvelopeCursor(nil, complete: false, mailboxId: 10, lastSyncAt: 1)
        #expect(try await iterator.next() == [])
    }
}
