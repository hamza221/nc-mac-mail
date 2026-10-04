// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// Every `ComposeRequest` case, routed against an in-memory mirror (WS-27).
@Suite("Compose request routing")
@MainActor
struct ComposeRoutingTests {
    let store: MailStore
    let identity = ServerIdentity(serverURL: URL(string: "https://cloud.example.com")!, loginName: "me")

    init() throws {
        store = try MailStore.inMemory()
    }

    private struct Fixture {
        var accountId: Int64
        var mailboxId: Int64
        var messageId: Int64
    }

    /// One account (me@example.com, alias alias@example.com), one Inbox, one message from
    /// Alice to me and Bob, Cc Carol, with a body and two attachments (one inline).
    private func fixture(subject: String = "AW: Quarterly numbers", replyTo: String? = nil) async throws -> Fixture {
        let account = try #require(
            try await store.upsert(accounts: [
                AccountWrite(identity: identity, remoteId: 1, name: "Me", emailAddress: "me@example.com")
            ]).first)
        try await store.replaceAliases(
            [AliasRecord(accountId: account.id, remoteId: 7, email: "alias@example.com", name: "Alias", rawJSON: "{}")],
            accountId: account.id)
        let mailbox = try #require(
            try await store.upsert(
                mailboxes: [MailboxWrite(accountId: account.id, remoteId: 5, name: "INBOX", displayName: "Inbox")],
                accountId: account.id
            ).first)
        var addresses = [
            EnvelopeAddress(kind: .from, email: "alice@example.com", label: "Alice"),
            EnvelopeAddress(kind: .to, email: "me@example.com"),
            EnvelopeAddress(kind: .to, email: "bob@example.com"),
            EnvelopeAddress(kind: .cc, email: "carol@example.com"),
        ]
        if let replyTo { addresses.append(EnvelopeAddress(kind: .replyTo, email: replyTo)) }
        var flags = MessageFlags()
        flags.hasAttachments = true
        let ids = try await store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: 42, mailboxId: mailbox.id, accountId: account.id, sentAt: 1_790_000_000,
                syncedAt: 1_790_000_000, uid: 300, messageId: "<abc@example.com>", subject: subject,
                previewText: "Numbers attached", flags: flags, fromEmail: "alice@example.com", fromLabel: "Alice",
                addresses: addresses)
        ])
        let messageId = try #require(ids.first)
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1_790_000_000, hasHtmlBody: true, html: "<p>The numbers</p>", plainBody: "The numbers",
                attachments: [
                    AttachmentWrite(
                        attachmentId: "2", isInline: false, fileName: "q3.pdf", mime: "application/pdf", size: 100),
                    AttachmentWrite(
                        attachmentId: "3", isInline: true, fileName: "logo.png", mime: "image/png", size: 12,
                        cid: "logo",
                        isImage: true),
                ]),
            for: messageId)
        return Fixture(accountId: account.id, mailboxId: mailbox.id, messageId: messageId)
    }

    private func seed(_ request: ComposeRequest, preferred: Int64? = nil) async -> ComposeSeed {
        await ComposeSeedBuilder.seed(for: request, store: store, preferredAccountId: preferred)
    }

    @Test func newMessageUsesTheMailboxOnScreen() async throws {
        let fixture = try await fixture()
        let seed = await seed(.new(accountId: nil, mailto: nil), preferred: fixture.accountId)
        #expect(seed.kind == .new)
        #expect(seed.accountId == fixture.accountId)
        #expect(seed.to.isEmpty)
        #expect(seed.insertsSignature)
        #expect(!seed.focusesBody)
    }

    @Test func newMessageFromMailto() async throws {
        _ = try await fixture()
        let seed = await seed(.new(accountId: nil, mailto: URL(string: "mailto:x@y.z?subject=Hi&body=Hello")))
        #expect(seed.to.map(\.email) == ["x@y.z"])
        #expect(seed.subject == "Hi")
        #expect(seed.body == "Hello")
    }

    @Test func replyPrefillsAndQuotes() async throws {
        let fixture = try await fixture()
        let seed = await seed(.reply(messageId: fixture.messageId, mode: .sender))
        #expect(seed.kind == .reply)
        #expect(seed.to.map(\.email) == ["alice@example.com"])
        #expect(seed.cc.isEmpty)
        // "AW:" is a reply prefix: no "Re: AW:".
        #expect(seed.subject == "AW: Quarterly numbers")
        #expect(seed.inReplyToMessageId == "<abc@example.com>")
        #expect(seed.quoteHTML?.contains(#"<blockquote type="cite"><p>The numbers</p></blockquote>"#) == true)
        #expect(seed.quotePlain?.hasSuffix("> The numbers") == true)
        // A reply copies only inline images.
        #expect(seed.attachments.map(\.kind) == ["message-attachment-inline"])
        #expect(seed.focusesBody)
    }

    @Test func replyAllPrefill() async throws {
        let fixture = try await fixture()
        let seed = await seed(.reply(messageId: fixture.messageId, mode: .all))
        #expect(seed.to.map(\.email) == ["alice@example.com", "bob@example.com"])
        #expect(seed.cc.map(\.email) == ["carol@example.com"])
    }

    @Test func replyHonoursReplyTo() async throws {
        let fixture = try await fixture(replyTo: "team@example.com")
        let seed = await seed(.reply(messageId: fixture.messageId, mode: .sender))
        #expect(seed.to.map(\.email) == ["team@example.com"])
    }

    @Test func smartReplyIsMarkedAIGenerated() async throws {
        let fixture = try await fixture()
        let seed = await seed(.smartReply(messageId: fixture.messageId, text: "Sounds good"))
        #expect(seed.body == "Sounds good")
        #expect(seed.isAiGenerated)
        #expect(seed.to.map(\.email) == ["alice@example.com"])
    }

    @Test func forwardCarriesEveryAttachment() async throws {
        let fixture = try await fixture(subject: "Quarterly numbers")
        let seed = await seed(.forward(messageIds: [fixture.messageId], asAttachment: false))
        #expect(seed.kind == .forward)
        #expect(seed.subject == "Fwd: Quarterly numbers")
        #expect(seed.to.isEmpty)
        #expect(seed.attachments.map(\.fileName) == ["q3.pdf", "logo.png"])
        let payload = try #require(seed.attachments.first?.payloadJSON)
        #expect(payload.contains(#""type":"message-attachment""#))
        #expect(payload.contains(#""mailboxId":5"#))
        #expect(payload.contains(#""uid":300"#))
        #expect(seed.quoteHTML?.contains("Forwarded message") == true)
    }

    @Test func forwardAsAttachmentIsAnEml() async throws {
        let fixture = try await fixture(subject: "Quarterly numbers")
        let seed = await seed(.forward(messageIds: [fixture.messageId], asAttachment: true))
        #expect(seed.attachments.count == 1)
        #expect(seed.attachments.first?.fileName == "Quarterly numbers.eml")
        #expect(seed.attachments.first?.payloadJSON.contains(#""type":"message""#) == true)
        #expect(seed.attachments.first?.payloadJSON.contains(#""id":42"#) == true)
        #expect(seed.quoteHTML == nil)
    }

    @Test func editAsNewSaysAttachmentsWereNotCopied() async throws {
        let fixture = try await fixture()
        let seed = await seed(.editAsNew(messageId: fixture.messageId))
        #expect(seed.kind == .new)
        #expect(seed.to.map(\.email) == ["me@example.com", "bob@example.com"])
        #expect(seed.subject == "AW: Quarterly numbers")
        #expect(seed.attachments.isEmpty)
        #expect(seed.notice == "Attachments were not copied. Please add them manually.")
        #expect(!seed.insertsSignature)
    }

    @Test func draftReplacesTheImapCopy() async throws {
        let fixture = try await fixture()
        let seed = await seed(.draft(draftId: fixture.messageId))
        #expect(seed.kind == .draft)
        #expect(seed.replacesMessageId == 42)
        #expect(seed.bodyIsHTML)
        #expect(!seed.insertsSignature)
    }

    @Test func outboxEntryBecomesADraft() async throws {
        let fixture = try await fixture()
        try await store.replaceOutbox(
            [
                OutboxMessageRecord(
                    accountId: fixture.accountId, remoteId: 77, aliasRemoteId: 7, subject: "Later",
                    bodyHtml: "<p>x</p>",
                    isHtml: true, requestMdn: true, sendAt: 1_800_000_000,
                    recipientsJSON: #"[{"kind":"to","email":"bob@example.com","label":null}]"#,
                    attachmentsJSON: #"[{"id":9,"fileName":"a.txt","mimeType":"text/plain","type":"local"}]"#,
                    syncedAt: 1)
            ], accountId: fixture.accountId)
        let outboxId = try #require(try await store.outboxMessages().first?.id)
        let seed = await seed(.outbox(outboxId: outboxId))
        #expect(seed.kind == .outbox)
        #expect(seed.to.map(\.email) == ["bob@example.com"])
        #expect(seed.sendAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(seed.requestMdn)
        #expect(seed.replacesOutboxId == outboxId)
        #expect(seed.aliasId != nil)
        #expect(seed.attachments.first?.payloadJSON == #"{"id":9,"type":"local"}"#)
    }

    @Test func missingMessageFails() async throws {
        _ = try await fixture()
        let seed = await seed(.reply(messageId: 9999, mode: .sender))
        #expect(seed.failure != nil)
    }

    @Test func missingSharedItemFails() async throws {
        _ = try await fixture()
        let seed = await seed(.shared(inboxItemId: UUID().uuidString))
        #expect(seed.failure == "The shared item could not be found.")
    }
}
