// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

@testable import NextcloudMail

/// An in-memory mirror with as many accounts as a test needs, each with an inbox and the
/// special folders it was asked for.
///
/// Every row goes in through `MailStore`'s public write path, so what the actions read is
/// what a sync would have written. The `remoteId`s and the local ids are deliberately
/// different numbers: `account.archiveMailboxId` holds the server's, `message.mailboxId`
/// holds the mirror's, and confusing the two is the mistake
/// [offline-queue.md](../../docs/architecture/offline-queue.md) spends a paragraph on.
struct TriageMirror: Sendable {
    /// One account of the mirror.
    struct Account: Sendable {
        let id: Int64
        let inboxId: Int64
        let archiveId: Int64?
        let junkId: Int64?
        let trashId: Int64?
    }

    let store: MailStore
    private(set) var accounts: [Account] = []

    /// Which special folders an account gets. The live test server has `archiveMailboxId`
    /// null, so an account without one is the ordinary case rather than the exotic one.
    struct Roles: Sendable {
        var archive = true
        var junk = true
        var trash = true

        static let all = Roles()
        static let none = Roles(archive: false, junk: false, trash: false)
    }

    static func seed(accounts roles: [Roles] = [.all]) async throws -> TriageMirror {
        let store = try MailStore.inMemory()
        var mirror = TriageMirror(store: store)
        for (index, role) in roles.enumerated() {
            mirror.accounts.append(try await mirror.addAccount(index: index, roles: role))
        }
        return mirror
    }

    private func addAccount(index: Int, roles: Roles) async throws -> Account {
        let offset = Int64(index) * 100
        // The server's numbers for this account's folders. Chosen to collide with *another*
        // account's local mailbox ids on purpose: writing one of these into
        // `message.mailboxId` would file the message under someone else's folder, and a test
        // that never lets the numbers overlap would not notice.
        let remoteInbox = offset + 1
        let remoteArchive = offset + 2
        let remoteJunk = offset + 3
        let remoteTrash = offset + 4

        let identity = ServerIdentity(serverURL: "https://server\(index).example.invalid/", loginName: "lorelai")
        let written = try await store.upsert(accounts: [
            AccountWrite(
                identity: identity,
                remoteId: Int64(index) + 1,
                name: "Account \(index)",
                emailAddress: "lorelai\(index)@example.invalid",
                trashMailboxId: roles.trash ? remoteTrash : nil,
                archiveMailboxId: roles.archive ? remoteArchive : nil,
                junkMailboxId: roles.junk ? remoteJunk : nil
            )
        ])
        guard let account = written.first else { throw TriageMirrorError.accountNotWritten }

        var writes = [mailbox(account.id, remoteInbox, "INBOX", "inbox")]
        if roles.archive { writes.append(mailbox(account.id, remoteArchive, "Archive", "archive")) }
        if roles.junk { writes.append(mailbox(account.id, remoteJunk, "Junk", "junk")) }
        if roles.trash { writes.append(mailbox(account.id, remoteTrash, "Trash", "trash")) }
        let mailboxes = try await store.upsert(mailboxes: writes, accountId: account.id)

        func local(_ remoteId: Int64) -> Int64? { mailboxes.first { $0.remoteId == remoteId }?.id }
        guard let inboxId = local(remoteInbox) else { throw TriageMirrorError.mailboxNotWritten }
        return Account(
            id: account.id,
            inboxId: inboxId,
            archiveId: local(remoteArchive),
            junkId: local(remoteJunk),
            trashId: local(remoteTrash)
        )
    }

    private func mailbox(_ accountId: Int64, _ remoteId: Int64, _ name: String, _ role: String) -> MailboxWrite {
        MailboxWrite(
            accountId: accountId,
            remoteId: remoteId,
            name: name,
            delimiter: ".",
            displayName: name,
            specialRole: role,
            isSubscribed: true
        )
    }

    /// Writes `count` messages into a mailbox, newest last.
    ///
    /// - Parameters:
    ///   - threadRootId: one value for all of them, which is how a thread is built. Nil gives
    ///     each message a root of its own, so it is a thread of one.
    ///   - seen: whether they arrive read.
    @discardableResult
    func addMessages(
        count: Int,
        account: Account,
        mailboxId: Int64? = nil,
        firstRemoteId: Int64 = 1,
        threadRootId: String? = nil,
        seen: Bool = false,
        flagged: Bool = false,
        important: Bool = false
    ) async throws -> [Int64] {
        let target = mailboxId ?? account.inboxId
        let envelopes = (0..<count).map { offset -> EnvelopeWrite in
            var flags = MessageFlags()
            flags.isSeen = seen
            flags.isFlagged = flagged
            flags.isImportant = important
            let remoteId = firstRemoteId + Int64(offset)
            return EnvelopeWrite(
                remoteId: remoteId,
                mailboxId: target,
                accountId: account.id,
                sentAt: 1_700_000_000 + remoteId,
                syncedAt: 1_700_000_000 + remoteId,
                messageId: "<\(account.id)-\(remoteId)@example.invalid>",
                threadRootId: threadRootId ?? "<thread-\(account.id)-\(remoteId)@example.invalid>",
                // Scrubbed exactly as `Scripts/record-fixtures.sh --scrub-content` leaves it.
                subject: "Subject redacted",
                previewText: "Preview redacted",
                flags: flags,
                fromEmail: "sender@example.invalid",
                fromLabel: "Name redacted",
                addresses: [
                    EnvelopeAddress(kind: .from, email: "sender@example.invalid", label: "Name redacted")
                ]
            )
        }
        return try await store.upsert(envelopes: envelopes)
    }

    func message(_ id: Int64) async throws -> MessageRecord? {
        try await store.message(id: id)
    }

    func queueDepth(_ account: Account) async throws -> Int {
        try await store.pendingOperations(accountId: account.id).count
    }

    enum TriageMirrorError: Error {
        case accountNotWritten
        case mailboxNotWritten
    }
}

/// A selection source holding rows read back from a real mirror, for the tests about where
/// the cursor lands after an action. `MessageListStore` is the production conformance; this
/// one exists so the advance rule can be asserted without waiting on an observation.
@MainActor
final class StubSelectionSource: TriageSelectionSource {
    var rows: [MessageRow] = []
    var selection: Set<Int64> = []

    init(rows: [MessageRow] = [], selection: Set<Int64> = []) {
        self.rows = rows
        self.selection = selection
    }
}
