// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailStore
import Testing

@testable import NCMailSync

/// The wire-to-store translation, against recorded payloads and no database.
///
/// Every fixture here came off the live server through `Scripts/record-fixtures.sh`. A
/// hand-written one would only prove that the mapping agrees with what the author imagined
/// the payload looked like, which is the thing most likely to be wrong.
@Suite("Mirror mapping")
struct MirrorMappingTests {
    /// One signed-in login, the thing that makes a server's numeric ids mean something
    /// (ADR-0033).
    private static let identity = ServerIdentity(
        serverURL: "https://cloud.example.invalid/",
        loginName: "user"
    )

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: try FixtureBytes.data(name))
    }

    // MARK: - Accounts

    @Test("an account maps id, addresses and every special mailbox, archive included when it is null")
    func accountMapping() throws {
        let accounts = try decode([RawBacked<Account>].self, "accounts.json")
        let writes = try accounts.map { try MirrorMapping.accountWrite($0, identity: Self.identity) }

        #expect(writes.count == accounts.count)
        let first = try #require(writes.first)
        let raw = try #require(try rawObjects("accounts.json").first)
        #expect(first.remoteId == (raw["id"] as? NSNumber)?.int64Value)
        #expect(first.serverURL == Self.identity.serverURL)
        #expect(first.loginName == "user")
        #expect(first.emailAddress == raw["emailAddress"] as? String)
        // The live test account has no archive folder. Nothing may assume this is set.
        #expect(raw["archiveMailboxId"] is NSNull)
        #expect(first.archiveMailboxId == nil)
        #expect(first.sortOrder == (raw["order"] as? NSNumber)?.intValue)
    }

    @Test("rawJSON keeps the fields no model names, so nothing needs a refetch to read them later")
    func accountRawJSONKeepsUnmodelledFields() throws {
        let accounts = try decode([RawBacked<Account>].self, "accounts.json")
        let write = try MirrorMapping.accountWrite(try #require(accounts.first), identity: Self.identity)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(write.rawJSON.utf8)) as? [String: Any]
        )
        // `imapHost` and `aliases` are in the payload and in no Swift model.
        #expect(parsed["imapHost"] != nil)
        #expect(parsed["aliases"] != nil)
    }

    // MARK: - Mailboxes

    @Test("subscription and selectability come off the raw IMAP attributes, case-folded")
    func mailboxSubscription() throws {
        let list = try decode(MailboxList.self, "mailboxes-account.json")
        let raw = try rawObjects("mailboxes-account.json", key: "mailboxes")
        let writes = try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: 42) }

        #expect(writes.count == raw.count)
        // Read off the raw payload, case-folded, independently of the mapping under test.
        let expected = raw.filter { entry in
            (entry["attributes"] as? [String] ?? []).contains { $0.lowercased() == "\\subscribed" }
        }
        .compactMap { ($0["databaseId"] as? NSNumber)?.int64Value }
        .sorted()
        let subscribed = writes.filter(\.isSubscribed).map(\.remoteId).sorted()
        #expect(subscribed == expected)
        // ADR-0007's test case, and not a bug in the recording: folders the user hid. The
        // live account is seeded with them so the recording carries both kinds.
        #expect(subscribed.count < writes.count, "the recording must hold an unsubscribed folder")
        #expect(writes.allSatisfy { $0.isSelectable })

        let inboxRaw = try #require(raw.first { $0["specialRole"] as? String == "inbox" })
        let inboxId = try #require((inboxRaw["databaseId"] as? NSNumber)?.int64Value)
        let inbox = try #require(writes.first { $0.remoteId == inboxId })
        #expect(inbox.specialRole == "inbox")
        // The local account id it was mapped for, never the one in the payload (ADR-0033).
        #expect(inbox.accountId == 42)
        #expect(inbox.unreadCount == (inboxRaw["unread"] as? NSNumber)?.intValue)
        #expect(inbox.attributesJSON.contains("subscribed"))
    }

    @Test("a specialRole the server sends as the integer 0 becomes null, not \"0\"")
    func mailboxSpecialRoleFallback() throws {
        let list = try decode(MailboxList.self, "mailboxes-account.json")
        let raw = try rawObjects("mailboxes-account.json", key: "mailboxes")
        let writes = try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: 1) }
        // A plain folder the user hid: the server writes `0` for its role, and lists no
        // `\subscribed` attribute.
        let plain = try #require(
            raw.first { entry in
                (entry["specialRole"] as? NSNumber)?.intValue == 0 && !(entry["specialRole"] is String)
                    && (entry["attributes"] as? [String] ?? []).allSatisfy { $0.lowercased() != "\\subscribed" }
            },
            "the recording must hold an unsubscribed folder with no special role"
        )
        let plainId = try #require((plain["databaseId"] as? NSNumber)?.int64Value)
        let unsubscribed = try #require(writes.first { $0.remoteId == plainId })
        #expect(unsubscribed.specialRole == nil)
        #expect(unsubscribed.isSubscribed == false)
    }

    @Test("a mailbox write has no isMirrored to get wrong: the store derives it")
    func mailboxWriteCannotSetMirrored() throws {
        let list = try decode(MailboxList.self, "mailboxes-account.json")
        let write = try MirrorMapping.mailboxWrite(try #require(list.entries.first), accountId: 1)
        let columns = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(write)) as? [String: Any]
        )
        #expect(columns["isMirrored"] == nil)
        #expect(columns["envelopeCursor"] == nil)
        #expect(columns["bodyState"] == nil)
    }

    // MARK: - Envelopes

    @Test("an envelope maps its flags, its sender and its addresses, and takes sentAt from dateInt")
    func envelopeMapping() throws {
        let page = try decode([RawBacked<Envelope>].self, "messages-inbox-page1.json")
        let raw = try rawObjects("messages-inbox-page1.json")
        let writes = try page.map {
            try MirrorMapping.envelopeWrite($0, accountId: 1, mailboxId: 77, syncedAt: 1_700_000_000)
        }

        #expect(writes.count == raw.count)
        let newest = try #require(writes.first)
        let newestRaw = try #require(raw.first)
        #expect(newest.remoteId == (newestRaw["databaseId"] as? NSNumber)?.int64Value)
        // The mailbox the caller was enumerating, not the id in the payload (ADR-0033).
        #expect(newest.mailboxId == 77)
        #expect(newest.accountId == 1)
        #expect(newest.sentAt == (newestRaw["dateInt"] as? NSNumber)?.int64Value)
        #expect(newest.syncedAt == 1_700_000_000)
        #expect(newest.fromEmail != nil)
        #expect(newest.addresses.contains { $0.kind == .from })
        // Every flag of every recorded envelope, against the raw payload's own keys.
        for (entry, write) in zip(raw, writes) {
            let flags = try #require(entry["flags"] as? [String: Any])
            #expect(write.isSeen == (flags["seen"] as? Bool ?? false))
            #expect(write.isFlagged == (flags["flagged"] as? Bool ?? false))
            #expect(write.isJunk == (flags["$junk"] as? Bool ?? false))
            #expect(write.isNotJunk == (flags["$notjunk"] as? Bool ?? false))
        }
    }

    @Test("every recorded envelope keeps at least one address, and none of them is blank")
    func envelopeAddressesAreUsable() throws {
        let page = try decode([RawBacked<Envelope>].self, "messages-inbox-page1.json")
        let writes = try page.map { try MirrorMapping.envelopeWrite($0, accountId: 1, mailboxId: 5, syncedAt: 1) }
        // `messageAddress.email` is NOT NULL, so an address with no email must be dropped
        // rather than written as "".
        #expect(writes.allSatisfy { $0.addresses.allSatisfy { !$0.email.isEmpty } })
        #expect(writes.allSatisfy { !$0.addresses.isEmpty })
    }

    @Test("an envelope with no references stores null rather than an empty array")
    func envelopeReferences() throws {
        let page = try decode([RawBacked<Envelope>].self, "messages-inbox-page1.json")
        let writes = try page.map { try MirrorMapping.envelopeWrite($0, accountId: 1, mailboxId: 5, syncedAt: 1) }
        let unreferenced = writes.filter { $0.referencesJSON == nil }
        #expect(!unreferenced.isEmpty)
        for write in writes {
            if let json = write.referencesJSON { #expect(json.hasPrefix("[")) }
        }
    }

    @Test("hasAttachments is true when the envelope lists attachments even if the flag does not")
    func envelopeAttachmentFlag() throws {
        let page = try decode([RawBacked<Envelope>].self, "messages-inbox-page1.json")
        let writes = try page.map { try MirrorMapping.envelopeWrite($0, accountId: 1, mailboxId: 5, syncedAt: 1) }
        for (raw, write) in zip(page, writes) where !raw.value.attachments.isEmpty {
            #expect(write.hasAttachments)
        }
    }

    // MARK: - Bodies

    @Test("an HTML message stores the sanitised fragment and no plain body")
    func bodyMappingHTML() throws {
        // The recorder's own HTML self-send: `message-html-plain.html` is this message's
        // sanitised fragment, recorded from the same message.
        let body = try decode(RawBacked<MessageBody>.self, "message-body-attachments.json")
        try #require(body.value.hasHtmlBody, "the recorder's HTML self-send must have an HTML part")
        let fragment = String(decoding: try FixtureBytes.data("message-html-plain.html"), as: UTF8.self)
        let write = try MirrorMapping.bodyWrite(body, html: fragment, fetchedAt: 1_700_000_042)

        #expect(write.hasHtmlBody)
        #expect(write.html == fragment)
        #expect(write.plainBody == nil)
        #expect(write.fetchedAt == 1_700_000_042)
        #expect(write.sanitiserGeneration == MirrorMapping.sanitiserGeneration)
        // `smime` and `phishingDetails` are real objects in this recording and are kept as
        // JSON: nothing in v1 reads inside them, and modelling them would be guesswork.
        #expect(write.smimeJSON?.contains("isSigned") == true)
        #expect(write.phishingJSON?.contains("checks") == true)
        // `scheduling` arrives as an empty array, not as null, and is stored as the server
        // sent it. Only a literal null becomes no column value at all, so the column never
        // holds the four characters `null` for something the server did report.
        #expect(write.schedulingJSON == "[]")
        #expect(write.itinerariesJSON == nil)
    }

    @Test("a body whose html fragment 404'd keeps the copy that came with the body")
    func bodyMappingFallsBackToTheBodyField() throws {
        let body = try decode(RawBacked<MessageBody>.self, "message-body-attachments.json")
        try #require(body.value.hasHtmlBody, "the recorder's HTML self-send must have an HTML part")
        let write = try MirrorMapping.bodyWrite(body, html: nil, fetchedAt: 1)
        #expect(write.hasHtmlBody)
        #expect(write.html == body.value.body)
        #expect(write.html?.isEmpty == false)
    }

    @Test("attachments carry their cid and disposition through, inline and not")
    func bodyMappingAttachments() throws {
        let body = try decode(RawBacked<MessageBody>.self, "message-body-attachments.json")
        let write = try MirrorMapping.bodyWrite(body, html: nil, fetchedAt: 1)

        #expect(write.attachments.count == body.value.attachments.count + body.value.inlineAttachments.count)
        let raw = try #require(try rawObject("message-body-attachments.json")["attachments"] as? [[String: Any]])
        let first = try #require(raw.first)
        let attachment = try #require(write.attachments.first)
        #expect(attachment.attachmentId == first["id"] as? String)
        #expect(attachment.cid == first["cid"] as? String)
        #expect(attachment.disposition == first["disposition"] as? String)
        #expect(attachment.isInline == false)
        #expect(attachment.downloadUrl != nil)
        let inlineIds = Set(body.value.inlineAttachments.map(\.id))
        for entry in write.attachments {
            #expect(entry.isInline == inlineIds.contains(entry.attachmentId))
        }
    }

    @Test("the body's rawJSON keeps every unmodelled field and drops the one that is stored twice")
    func bodyRawJSONDropsTheDuplicatedText() throws {
        let body = try decode(RawBacked<MessageBody>.self, "message-body.json")
        let write = try MirrorMapping.bodyWrite(body, html: "<p>hi</p>", fetchedAt: 1)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(write.rawJSON.utf8)) as? [String: Any]
        )
        // `body` lives in the `html` column. Keeping the server's copy too put every
        // message's text on disk twice: measured at 41% of a full mirror of the live
        // account. ADR-0032.
        #expect(parsed["body"] == nil)
        // Everything the client does not model still survives, which is the whole point of
        // the column.
        #expect(parsed["isPgpMimeEncrypted"] != nil)
        #expect(parsed["hasDkimSignature"] != nil)
        #expect(parsed["databaseId"] != nil)
    }

    @Test("a body write carries no byteSize, because the store measures what it actually stored")
    func bodyWriteHasNoByteSize() throws {
        let body = try decode(RawBacked<MessageBody>.self, "message-body.json")
        let write = try MirrorMapping.bodyWrite(body, html: "<p>hi</p>", fetchedAt: 1)
        // A compile-time fact more than a runtime one: `MessageBodyWrite` has no such
        // property to set, so the storage panel's total cannot drift from the bytes.
        #expect(Mirror(reflecting: write).children.allSatisfy { $0.label != "byteSize" })
    }

    /// The recording as plain JSON, so an expectation is read from what the server sent
    /// rather than typed into the test — and not through the model under test.
    private func rawObject(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: try FixtureBytes.data(name)) as? [String: Any])
    }

    private func rawObjects(_ name: String, key: String? = nil) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: try FixtureBytes.data(name))
        let list: Any? = if let key { (object as? [String: Any])?[key] } else { object }
        return try #require(list as? [[String: Any]])
    }
}
