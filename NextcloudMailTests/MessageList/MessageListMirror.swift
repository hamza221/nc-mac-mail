// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// An in-memory mirror with one account and one mailbox, for the message list's tests.
///
/// Everything goes through `MailStore`'s public write path, so the rows the list reads are
/// the rows the sync engine would have written — including the search-index rows and the
/// addresses, which a hand-built row would not have. No subject or sender text is ever
/// asserted on: the recorded fixtures are scrubbed, and a list test that depends on the word
/// in a subject is testing the recorder.
struct MessageListMirror: Sendable {
    let store: MailStore
    let accountId: Int64
    let mailboxId: Int64

    private static let identity = ServerIdentity(serverURL: "https://one.example.invalid/", loginName: "lorelai")

    static func seed() async throws -> MessageListMirror {
        let store = try MailStore.inMemory()
        let accounts = try await store.upsert(accounts: [
            AccountWrite(identity: identity, remoteId: 1, name: "Work", emailAddress: "lorelai@example.invalid")
        ])
        guard let account = accounts.first else { throw MirrorSeedError.accountNotWritten }
        let mailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id,
                    remoteId: 1005,
                    name: "INBOX",
                    delimiter: ".",
                    displayName: "Inbox",
                    specialRole: "inbox",
                    isSubscribed: true
                )
            ],
            accountId: account.id
        )
        guard let mailbox = mailboxes.first else { throw MirrorSeedError.mailboxNotWritten }
        return MessageListMirror(store: store, accountId: account.id, mailboxId: mailbox.id)
    }

    /// Writes one envelope per `sentAt`, oldest id first.
    ///
    /// - Parameters:
    ///   - threadRootId: One value for every message written here, which is how a thread of
    ///     several is built. Nil leaves each message a thread of one.
    ///   - threadSize: Threads of exactly this many messages, keyed off the server id, for a
    ///     fixture too large to list thread by thread. Ignored when `threadRootId` is set.
    ///   - seenEvery: Marks every nth message read, counting from one, so a fixture has a
    ///     mix without the test having to list flags per message.
    @discardableResult
    func addMessages(
        sentAt: [Int64],
        firstRemoteId: Int64 = 1,
        into mailbox: Int64? = nil,
        threadRootId: String? = nil,
        threadSize: Int? = nil,
        seenEvery: Int? = nil,
        isFlagged: Bool = false,
        hasAttachments: Bool = false,
        isAnswered: Bool = false,
        isImportant: Bool = false,
        isDraft: Bool = false,
        tags: [TagWrite] = [],
        account: Int64? = nil
    ) async throws -> [Int64] {
        let target = mailbox ?? mailboxId
        let envelopes = sentAt.enumerated().map { offset, moment -> EnvelopeWrite in
            var flags = MessageFlags()
            flags.isSeen = seenEvery.map { (offset + 1) % $0 == 0 } ?? false
            flags.isFlagged = isFlagged
            flags.hasAttachments = hasAttachments
            flags.isAnswered = isAnswered
            flags.isImportant = isImportant
            flags.isDraft = isDraft
            let remoteId = firstRemoteId + Int64(offset)
            return EnvelopeWrite(
                remoteId: remoteId,
                mailboxId: target,
                accountId: account ?? accountId,
                sentAt: moment,
                syncedAt: moment,
                messageId: "<\(remoteId)@example.invalid>",
                threadRootId: threadRootId
                    ?? threadSize.map { "<thread-\((remoteId - 1) / Int64($0))@example.invalid>" },
                // Scrubbed exactly as `Scripts/record-fixtures.sh --scrub-content` leaves it,
                // so nothing here can tempt a test into asserting on text.
                subject: "Subject redacted",
                previewText: "Preview redacted",
                flags: flags,
                fromEmail: "sender@example.invalid",
                fromLabel: "Name redacted",
                addresses: [
                    EnvelopeAddress(kind: .from, email: "sender@example.invalid", label: "Name redacted"),
                    EnvelopeAddress(kind: .to, email: "lorelai@example.invalid", label: "Name redacted"),
                ],
                tags: tags
            )
        }
        return try await store.upsert(envelopes: envelopes)
    }

    /// A second account on another login, with its own Inbox, for the merged lists.
    func addAccount(loginName: String, remoteId: Int64) async throws -> (accountId: Int64, inboxId: Int64) {
        let identity = ServerIdentity(serverURL: "https://two.example.invalid/", loginName: loginName)
        let accounts = try await store.upsert(accounts: [
            AccountWrite(
                identity: identity, remoteId: remoteId, name: "Home", emailAddress: "\(loginName)@example.invalid")
        ])
        guard let account = accounts.first else { throw MirrorSeedError.accountNotWritten }
        let mailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id, remoteId: remoteId * 1000, name: "INBOX", delimiter: ".",
                    displayName: "Inbox", specialRole: "inbox", isSubscribed: true)
            ],
            accountId: account.id
        )
        guard let inbox = mailboxes.first else { throw MirrorSeedError.mailboxNotWritten }
        return (account.id, inbox.id)
    }

    /// A second mailbox on the same account, for the tests about replacing an observation.
    func addMailbox(remoteId: Int64, name: String) async throws -> Int64 {
        let mailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: accountId,
                    remoteId: remoteId,
                    name: name,
                    delimiter: ".",
                    displayName: name,
                    isSubscribed: true
                )
            ],
            accountId: accountId
        )
        guard let mailbox = mailboxes.first else { throw MirrorSeedError.mailboxNotWritten }
        return mailbox.id
    }

    /// Stamps the mailbox as fully enumerated, which is what turns "downloading" into
    /// "no messages".
    func finishEnumerating(mailbox: Int64? = nil) async throws {
        try await store.setEnvelopeCursor(nil, complete: true, mailboxId: mailbox ?? mailboxId, lastSyncAt: 1)
    }

    enum MirrorSeedError: Error {
        case accountNotWritten
        case mailboxNotWritten
    }
}

/// Spins the main actor until `condition` holds.
///
/// Yielding is what lets a pending `StoreObservation` delivery run, but the database write
/// behind a delivery happens off the main actor, so under load a yield count can be spent
/// before the write lands. The bound is a clock; it produces a failed expectation rather
/// than a hung suite.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, limit: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
