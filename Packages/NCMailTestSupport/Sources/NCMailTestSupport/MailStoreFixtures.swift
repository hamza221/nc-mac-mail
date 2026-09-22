// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
public import NCMailStore

/// Fills a `MailStore` with a plausible mailbox, for the tests that need a realistic mailbox
/// rather than a hand-rolled one: WS-03's own query-plan assertions, WS-08's windowing, and
/// WS-11's search ranking.
///
/// "Plausible" is the point. Identical rows make every index look brilliant — a query plan
/// that only ever sees one distinct subject or one sender never exercises the index the way a
/// real inbox does. Every message here varies its thread, its sender, its subject, its flags
/// and (optionally) its body, on top of the real write path (`MailStore.upsert`), so the
/// search index, the addresses table and the FTS trigger all get populated exactly as they
/// would from a live sync.
public enum MailStoreFixtures {
    /// What `seed` put in the store, so a test does not have to hard-code ids that only
    /// happen to match this function's internals.
    public struct SeedResult: Sendable {
        public let accountId: Int64
        public let mailboxId: Int64
        /// Oldest first, matching insertion order. `messageIds.last` is the newest message.
        public let messageIds: [Int64]
    }

    /// A handful of distinct subject topics, rotated across messages so full-text search has
    /// more than one term to rank. Not meant to be exhaustive — just not the same six words
    /// repeated fifty thousand times.
    private static let topics = [
        "invoices", "hedgehogs", "the roadmap", "deployment", "lunch", "the outage",
        "onboarding", "quarterly numbers", "the migration", "the retro",
    ]

    /// Inserts `messages` envelopes into a mailbox in `store`, through the real write path.
    ///
    /// - Parameters:
    ///   - store: an already-open `MailStore` (typically `.inMemory()`).
    ///   - messages: how many envelopes to write.
    ///   - accountId: the account they belong to; created if `account` write has not already
    ///     happened for this id.
    ///   - mailboxId: the mailbox they land in; created alongside the account.
    ///   - threadSize: messages per thread — `messages / threadSize` distinct threads.
    ///   - bodyFraction: the proportion (0...1) of messages that also get a stored body, taken
    ///     from a recorded fixture so the text is not one sentence repeated. 0 by default,
    ///     because most callers only need envelopes; body storage is real disk I/O that a
    ///     50,000-row query-plan test does not need to pay for.
    ///   - batchSize: how many envelopes go into one `upsert` call. GRDB batches inside a
    ///     single transaction either way; this just bounds how much sits in memory as
    ///     `EnvelopeWrite` values before it is handed to the store.
    @discardableResult
    public static func seed(
        _ store: MailStore,
        messages: Int,
        accountId: Int64 = 1,
        mailboxId: Int64 = 10,
        threadSize: Int = 5,
        bodyFraction: Double = 0,
        batchSize: Int = 1000
    ) async throws -> SeedResult {
        try await store.upsert(
            accounts: [AccountWrite(id: accountId, name: "Fixture account", emailAddress: "fixtures@example.invalid")]
        )
        try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    id: mailboxId,
                    accountId: accountId,
                    name: "INBOX",
                    displayName: "INBOX",
                    specialRole: "inbox",
                    isSubscribed: true,
                    unreadCount: 0
                )
            ],
            accountId: accountId
        )

        var body: String?
        if bodyFraction > 0 {
            body = String(decoding: try FixtureBytes.data("message-html-plain.html"), as: UTF8.self)
        }

        var ids: [Int64] = []
        ids.reserveCapacity(messages)
        var batch: [EnvelopeWrite] = []
        batch.reserveCapacity(min(batchSize, messages))

        for offset in 0..<messages {
            let id = Int64(offset) + 1
            ids.append(id)
            batch.append(envelope(id: id, accountId: accountId, mailboxId: mailboxId, threadSize: threadSize))
            if batch.count == batchSize {
                try await store.upsert(envelopes: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await store.upsert(envelopes: batch) }

        if let body, bodyFraction > 0 {
            // Every Nth message rather than a random sample: deterministic, so a test that
            // asserts a count does not flake on the one run where the dice landed differently.
            let stride = max(1, Int((1 / bodyFraction).rounded()))
            for id in Swift.stride(from: ids.first ?? 1, through: ids.last ?? 0, by: stride) {
                try await store.upsert(
                    body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: true, html: "<p>Message \(id)</p>" + body),
                    for: id
                )
            }
        }

        return SeedResult(accountId: accountId, mailboxId: mailboxId, messageIds: ids)
    }

    private static func envelope(id: Int64, accountId: Int64, mailboxId: Int64, threadSize: Int) -> EnvelopeWrite {
        let topic = topics[Int(id) % topics.count]
        var flags = MessageFlags()
        flags.isSeen = id % 3 == 0
        flags.isFlagged = id % 11 == 0
        flags.hasAttachments = id % 13 == 0
        flags.isAnswered = id % 17 == 0
        let sender = Int(id) % 500
        return EnvelopeWrite(
            id: id,
            mailboxId: mailboxId,
            accountId: accountId,
            sentAt: 1_600_000_000 + id,
            syncedAt: 1_600_000_000 + id,
            messageId: "<fixture-\(id)@example.invalid>",
            threadRootId: "thread-\(id / Int64(threadSize))",
            subject: "Message \(id) about \(topic)",
            previewText: "The quick brown fox jumped over the lazy dog, message \(id).",
            flags: flags,
            fromEmail: "sender\(sender)@example.invalid",
            fromLabel: "Sender \(sender)",
            addresses: [
                EnvelopeAddress(kind: .from, email: "sender\(sender)@example.invalid", label: "Sender \(sender)"),
                EnvelopeAddress(kind: .to, email: "me@example.invalid", label: "Me"),
            ]
        )
    }
}
