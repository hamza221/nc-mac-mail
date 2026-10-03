// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailCore

// One test per model, each against a fixture recorded from a live server.
//
// The recorder ran with --scrub-content, so `subject` and `previewText` are the
// literal strings "Subject redacted" and "Preview redacted" and every address is
// `user@example.com`. Nothing here asserts on that text: the assertions are
// about structure, types and the traps.

@Suite("Account")
struct AccountDecodingTests {
    @Test("accounts.json decodes")
    func decodesAccounts() throws {
        let accounts = try Fixture.decode([RawBacked<Account>].self, from: "accounts.json")
        #expect(!accounts.isEmpty)
        let first = try #require(accounts.first).value
        #expect(first.id > 0)
        #expect(!first.name.isEmpty)
        #expect(!first.emailAddress.isEmpty)
    }

    @Test("a missing special mailbox stays nil rather than failing")
    func toleratesMissingSpecialMailboxes() throws {
        let accounts = try Fixture.decode([RawBacked<Account>].self, from: "accounts.json")
        let account = try #require(accounts.first).value
        // The test server has no archive mailbox at all. Triage has to cope.
        #expect(account.archiveMailboxId == nil)
        #expect(account.trashMailboxId != nil)
    }

    @Test("the raw JSON keeps fields the model does not name")
    func keepsUnmodelledFields() throws {
        let accounts = try Fixture.decode([RawBacked<Account>].self, from: "accounts.json")
        let raw = try #require(accounts.first)
        let members = try #require(raw.json.objectValue)
        #expect(members["imapHost"] != nil)
        #expect(members["signatureMode"] != nil)
        #expect(members["authMethod"] != nil)
    }
}

@Suite("Mailbox")
struct MailboxDecodingTests {
    private func list() throws -> MailboxList {
        try Fixture.decode(MailboxList.self, from: "mailboxes-account.json")
    }

    @Test("mailboxes-account.json decodes")
    func decodesMailboxes() throws {
        let list = try list()
        #expect(list.accountId > 0)
        #expect(!list.mailboxes.isEmpty)
        #expect(!list.delimiter.isEmpty)
    }

    @Test("databaseId is the identifier and the base64 id is dropped")
    func usesDatabaseId() throws {
        let list = try list()
        for mailbox in list.mailboxes {
            #expect(mailbox.id > 0)
        }
        let raw = try #require(list.entries.first)
        // The payload still carries the base64 string; the model just ignores it.
        #expect(raw.json.objectValue?["id"] != nil)
        #expect(raw.value.id != 0)
    }

    @Test("specialRole decodes from both a string and the integer 0")
    func decodesSpecialRole() throws {
        let list = try list()
        #expect(list.mailboxes.map(\.specialRole).contains("inbox"))
        // The integer form means "no role", not the role "0". The recorder's
        // current server gives every folder a role, so the lenient path is
        // pinned inline rather than left to luck.
        let data = Data(#"{"databaseId":1,"accountId":1,"name":"Lists","specialRole":0}"#.utf8)
        let mailbox = try JSONDecoder().decode(Mailbox.self, from: data)
        #expect(mailbox.specialRole == nil)
    }

    @Test("subscription and selectability come out of attributes")
    func derivesSubscription() throws {
        let list = try list()
        #expect(list.mailboxes.contains { $0.isSubscribed })
        #expect(list.mailboxes.allSatisfy { $0.isSelectable })
        // ADR-0007's other half — a folder without \subscribed — is not in the
        // current recording (the dev server subscribes everything), so the
        // derivation is pinned inline.
        let data = Data(#"{"databaseId":1,"accountId":1,"name":"Lists","attributes":["\\hasnochildren"]}"#.utf8)
        let mailbox = try JSONDecoder().decode(Mailbox.self, from: data)
        #expect(!mailbox.isSubscribed)
    }

    @Test("subscription compares case-insensitively")
    func foldsAttributeCase() throws {
        let data = Data(
            #"{"databaseId":1,"accountId":1,"name":"INBOX","attributes":["\\Subscribed"]}"#.utf8
        )
        let mailbox = try JSONDecoder().decode(Mailbox.self, from: data)
        #expect(mailbox.isSubscribed)
    }

    @Test("displayName is the full path, and the leaf has to be derived")
    func leafNameIsDerived() throws {
        // No nested folder in the current recording, so the split is pinned
        // inline; the recorded flat folders keep the leaf == name case honest.
        let data = Data(
            #"{"databaseId":9,"accountId":1,"name":"INBOX/Work","displayName":"INBOX/Work","delimiter":"/"}"#.utf8
        )
        let nested = try JSONDecoder().decode(Mailbox.self, from: data)
        #expect(nested.displayName == nested.name)
        #expect(nested.leafName == "Work")
        for mailbox in try list().mailboxes where !mailbox.name.contains(mailbox.delimiter) {
            #expect(mailbox.leafName == mailbox.name)
        }
    }

    @Test("the flat list is flat: no mailbox nests another")
    func listIsFlat() throws {
        let list = try list()
        for entry in list.entries {
            let nested = entry.json.objectValue?["mailboxes"]
            #expect(nested == .array([]))
        }
    }
}

@Suite("Envelope")
struct EnvelopeDecodingTests {
    private func page() throws -> [RawBacked<Envelope>] {
        try Fixture.decode([RawBacked<Envelope>].self, from: "messages-inbox-page1.json")
    }

    /// One recorded envelope as a mutable JSON object, for pinning a payload
    /// variant the current recording happens not to contain. The base is still
    /// the recording — only the single field under test is replaced.
    private func recordedEnvelopeObject() throws -> [String: Any] {
        let page = try JSONSerialization.jsonObject(with: Fixture.data("messages-inbox-page1.json"))
        let first = (page as? [[String: Any]])?.first
        return try #require(first)
    }

    @Test("every envelope on page one decodes")
    func decodesEveryEnvelope() throws {
        // The count is whatever the recorder's server held that day; what must
        // hold is that every element decodes with its identifiers intact.
        let envelopes = try page().map(\.value)
        #expect(!envelopes.isEmpty)
        for envelope in envelopes {
            #expect(envelope.id > 0)
            #expect(envelope.mailboxId > 0)
            #expect(envelope.dateInt > 0)
        }
    }

    @Test("flags is an object with the dollar-prefixed keys spelled out")
    func decodesFlags() throws {
        let entries = try page()
        #expect(entries.contains { $0.value.flags.seen })
        // The dollar-prefixed keys are in every recorded payload. Their values
        // are whatever the mailbox held, so the assertion is that the keys are
        // present and the decode mapped them without throwing.
        for entry in entries {
            let flags = try #require(entry.json.objectValue?["flags"]?.objectValue)
            #expect(flags["$notjunk"] != nil)
            #expect(flags["$junk"] != nil)
            #expect(flags["$mdnsent"] != nil)
        }
    }

    @Test("tags decode from a dictionary and from the empty array PHP sends")
    func decodesTags() throws {
        for envelope in try page().map(\.value) where !envelope.tags.isEmpty {
            for (key, tag) in envelope.tags {
                #expect(key == tag.imapLabel)
                #expect(!tag.displayName.isEmpty)
            }
        }
        // PHP serialises an empty associative array as `[]`. Every message in
        // the current recording is tagged, so the array form is pinned by
        // surgically emptying a recorded envelope's tags.
        var object = try recordedEnvelopeObject()
        object["tags"] = [Any]()
        let data = try JSONSerialization.data(withJSONObject: object)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(envelope.tags.isEmpty)
    }

    @Test("mentionsMe arrives as 0 or 1, not as a boolean")
    func decodesIntegerBoolean() throws {
        let entries = try page()
        let asInteger = entries.filter {
            if case .int = $0.json.objectValue?["mentionsMe"] { return true }
            return false
        }
        #expect(!asInteger.isEmpty)
        // Nothing mentions the test user in the current recording, so the `1`
        // form is pinned by rewriting a recorded envelope's counter.
        var object = try recordedEnvelopeObject()
        object["mentionsMe"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(envelope.mentionsMe)
    }

    @Test("references is an array, never a string")
    func decodesReferences() throws {
        let envelopes = try page().map(\.value)
        #expect(envelopes.allSatisfy { $0.references.allSatisfy { !$0.isEmpty } })
    }

    @Test("the attachment records inside an envelope are the reduced shape")
    func decodesEnvelopeAttachments() throws {
        // The current recording has no envelope with attachments; when one
        // shows up again, the reduced shape is asserted — like the avatar case
        // below, an honest gap beats a flaky demand. The full body shape has
        // its own test against message-body-attachments.json.
        for envelope in try page().map(\.value) {
            for attachment in envelope.attachments {
                #expect(!attachment.id.isEmpty)
                // The envelope never runs enrichAttachment, so these are
                // absent here and present on the body.
                #expect(attachment.size == nil)
                #expect(attachment.disposition == nil)
            }
        }
    }

    // Whether an envelope carries an avatar is transient. Nextcloud resolves
    // them asynchronously and caches them, so the same request returns objects
    // while the cache is warm and nulls after it empties. A fixture cannot
    // promise either, and a test that demands one passes on Tuesdays. So the
    // null path is asserted unconditionally and the populated path only when
    // the recording happens to have one.

    @Test("a null avatar decodes to nil rather than throwing")
    func decodesMissingAvatar() throws {
        let entries = try page()
        let nulls = entries.filter { $0.json.objectValue?["avatar"] == .null }
        #expect(!nulls.isEmpty)
        #expect(nulls.allSatisfy { $0.value.avatar == nil })
        // The key is always present, so `avatar` is nullable rather than optional
        // in the payload's sense, and decodeIfPresent alone would not be enough.
        #expect(entries.allSatisfy { $0.json.objectValue?["avatar"] != nil })
    }

    @Test("an avatar that is present decodes with its URL")
    func decodesPresentAvatar() throws {
        let avatars = try page().map(\.value).compactMap(\.avatar)
        // Empty in the current recording. See the note above: this asserts the
        // shape when the server had one cached, and asserts nothing when it did
        // not, which is an honest gap rather than a flaky assertion.
        for avatar in avatars {
            #expect(avatar.url?.isEmpty == false)
        }
    }

    @Test("the thread endpoint returns envelopes too")
    func decodesThread() throws {
        let thread = try Fixture.decode([RawBacked<Envelope>].self, from: "message-thread.json")
        #expect(!thread.isEmpty)
        #expect(thread.allSatisfy { $0.value.id > 0 })
    }

    @Test("an empty page decodes as an empty array")
    func decodesEmptyPage() throws {
        let page = try Fixture.decode([RawBacked<Envelope>].self, from: "messages-inbox-page2.json")
        #expect(page.isEmpty)
    }
}

@Suite("MessageBody")
struct MessageBodyDecodingTests {
    @Test("message-body.json decodes")
    func decodesBody() throws {
        let body = try Fixture.decode(RawBacked<MessageBody>.self, from: "message-body.json").value
        #expect(body.id > 0)
        // Whether the recorded message was HTML or plain depends on what the
        // recorder found; either way the body text itself must survive.
        #expect(body.body?.isEmpty == false)
        #expect(!body.from.isEmpty)
    }

    @Test("body flags is an object, the same shape as the envelope's")
    func bodyFlagsAreAnObject() throws {
        let raw = try Fixture.decode(RawBacked<MessageBody>.self, from: "message-body.json")
        let flags = try #require(raw.json.objectValue?["flags"])
        #expect(flags.objectValue != nil)
        // `$junk` and `$notjunk` are the two keys the body omits; they default
        // to false rather than making the decode fail.
        #expect(flags.objectValue?["$junk"] == nil)
        #expect(!raw.value.flags.junk)
    }

    @Test("a body with an attachment decodes the full attachment shape")
    func decodesBodyAttachments() throws {
        let body = try Fixture.decode(
            RawBacked<MessageBody>.self,
            from: "message-body-attachments.json"
        ).value
        let attachment = try #require(body.attachments.first)
        #expect(attachment.id == "2")
        #expect(attachment.size ?? 0 > 0)
        #expect(attachment.disposition == "attachment")
        #expect(attachment.isImage == false)
        #expect(attachment.mime != nil)
    }

    @Test("the JSON blobs the store keeps verbatim survive decoding")
    func keepsOpaqueBlobs() throws {
        let body = try Fixture.decode(RawBacked<MessageBody>.self, from: "message-body.json").value
        #expect(body.smime?.objectValue != nil)
        #expect(body.phishingDetails?.objectValue != nil)
        #expect(body.scheduling != nil)
    }
}

@Suite("Sync")
struct SyncDecodingTests {
    @Test("an init sync decodes")
    func decodesInitialSync() throws {
        let sync = try Fixture.decode(SyncResponse.self, from: "sync-initial.json")
        #expect(!sync.newMessages.isEmpty)
        #expect(sync.vanishedMessages.isEmpty)
        let stats = try #require(sync.stats)
        #expect(stats.total == sync.newMessages.count)
    }

    @Test("an incremental sync returns the window back as changedMessages")
    func decodesIncrementalSync() throws {
        let sync = try Fixture.decode(SyncResponse.self, from: "sync-incremental.json")
        // The recorder sends its known-id window and the server echoes every id
        // that still exists — there is no change detection. The window size is
        // the recorder's choice, so only the echo property is asserted.
        #expect(!sync.changedMessages.isEmpty)
        #expect(sync.newMessages.isEmpty)
    }

    @Test("mailbox-stats.json decodes")
    func decodesStats() throws {
        let stats = try Fixture.decode(MailboxStats.self, from: "mailbox-stats.json")
        #expect(stats.total > 0)
        #expect(stats.unread <= stats.total)
    }
}

@Suite("Capabilities and preferences")
struct MiscDecodingTests {
    @Test("capabilities.json yields the theming colour")
    func decodesCapabilities() throws {
        let response = try Fixture.decode(OCSResponse<Capabilities>.self, from: "capabilities.json")
        #expect(response.meta.statuscode == 200)
        let color = try #require(response.data.theming?.color)
        #expect(color.hasPrefix("#"))
        #expect(response.data.version?.string != nil)
    }

    @Test("the sort-order preference decodes to a known order or to unset")
    func decodesPreference() throws {
        // The recorder writes the preference before reading it back, so the
        // value is whatever the last run set: a known order, or null on an
        // instance where nothing has written it yet.
        let preference = try Fixture.decode(Preference.self, from: "preference-sort-order.json")
        if let raw = preference.stringValue {
            #expect(SortOrder(rawValue: raw) != nil)
            #expect(SortOrder(preference: preference).rawValue == raw)
        } else {
            #expect(preference.value == .null)
            #expect(SortOrder(preference: preference) == .default)
        }
    }

    @Test("the trusted-sender list arrives inside a success envelope")
    func decodesTrustedSenders() throws {
        let response = try Fixture.decode(TrustedSendersResponse.self, from: "trustedsenders.json")
        #expect(response.status == "success")
        #expect(response.data.isEmpty)
    }
}
