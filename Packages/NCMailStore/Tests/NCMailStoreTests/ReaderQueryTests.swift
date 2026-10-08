// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// The four readers the view workstreams worked around, and the behaviour each workaround
/// was standing in for.
///
/// `observeBody` retires ADR-0038, `observeMailbox` retires ADR-0042, `addresses` replaces a
/// decode of `message.rawJSON`, and `avatar` is the reader the `avatar` table never had.
@Suite("Readers the views asked for")
struct ReaderQueryTests {
    /// The guarantee ADR-0038 was working around: the body write is one transaction, so a
    /// view observing the body sees it the instant the backfill commits it — with nothing
    /// polling and nothing asking the network.
    @Test("a body arriving reaches an observer of that one message")
    func observingOneBodyDeliversWhenItLands() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])

        var received: [String?] = []
        for try await stored in store.observeBody(messageId: 1) {
            received.append(stored?.body.plainBody)
            if received.count == 1 {
                try await Task.detached {
                    try await store.upsert(
                        body: MessageBodyWrite(fetchedAt: 200, plainBody: "the rest of it"),
                        for: 1
                    )
                }.value
            } else {
                break
            }
        }

        #expect(received == [nil, "the rest of it"])
        #expect(try await store.message(id: 1)?.bodyState == .present)
    }

    @Test("the body observation carries the attachments, because the renderer needs both")
    func observingABodyCarriesItsAttachments() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 200,
                hasHtmlBody: true,
                html: "<p>hello</p>",
                attachments: [
                    AttachmentWrite(attachmentId: "2", fileName: "second.png", mime: "image/png"),
                    AttachmentWrite(attachmentId: "1", fileName: "first.png", mime: "image/png"),
                ]
            ),
            for: 1
        )

        for try await stored in store.observeBody(messageId: 1) {
            #expect(stored?.attachments.map(\.attachmentId) == ["1", "2"])
            break
        }
    }

    /// ADR-0042's case: the mailbox is selected while it is still enumerating, and the
    /// column that decides between "Downloading messages" and "No messages" changes under
    /// the view.
    @Test("a mailbox's mirror progress reaches an observer of that one mailbox")
    func observingOneMailboxDeliversItsProgress() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)

        var received: [Bool] = []
        for try await mailbox in store.observeMailbox(id: 10) {
            received.append(mailbox?.envelopesComplete ?? false)
            if received.count == 1 {
                try await Task.detached {
                    try await store.setEnvelopeCursor(42, complete: true, mailboxId: 10, lastSyncAt: 1)
                }.value
            } else {
                break
            }
        }

        #expect(received == [false, true])
    }

    @Test("observing a mailbox that is not there delivers nil rather than failing")
    func observingAMissingMailboxDeliversNil() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)

        for try await mailbox in store.observeMailbox(id: 9_999) {
            #expect(mailbox == nil)
            break
        }
    }

    /// Without this reader a caller has to decode the envelope back out of
    /// `message.rawJSON` to name the recipients, because `message` denormalises only the
    /// sender.
    @Test("addresses come back in header order, from first and each kind in its own order")
    func addressesAreReadInHeaderOrder() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1,
                    sentAt: 100,
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "ada@example.invalid", label: "Ada"),
                        EnvelopeAddress(kind: .cc, email: "cc1@example.invalid"),
                        EnvelopeAddress(kind: .to, email: "to1@example.invalid", label: "First"),
                        EnvelopeAddress(kind: .to, email: "to2@example.invalid"),
                        EnvelopeAddress(kind: .cc, email: "cc2@example.invalid"),
                        EnvelopeAddress(kind: .replyTo, email: "reply@example.invalid"),
                    ]
                )
            ]
        )

        let addresses = try await store.addresses(messageId: 1)
        #expect(
            addresses.map(\.email) == [
                "ada@example.invalid",
                "to1@example.invalid", "to2@example.invalid",
                "cc1@example.invalid", "cc2@example.invalid",
                "reply@example.invalid",
            ]
        )
        #expect(addresses.first?.label == "Ada")
        #expect(addresses.filter { $0.kind == .to }.map(\.position) == [0, 1])
        #expect(try await store.addresses(messageId: 9_999).isEmpty)
    }

    /// A recipient removed server-side has to disappear here too: `upsert(envelopes:)`
    /// rewrites the rows rather than merging them.
    @Test("re-syncing an envelope replaces its addresses rather than adding to them")
    func addressesFollowTheLatestEnvelope() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1,
                    sentAt: 100,
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "ada@example.invalid"),
                        EnvelopeAddress(kind: .to, email: "gone@example.invalid"),
                    ]
                )
            ]
        )
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1,
                    sentAt: 100,
                    addresses: [EnvelopeAddress(kind: .from, email: "ada@example.invalid")]
                )
            ]
        )

        #expect(try await store.addresses(messageId: 1).map(\.email) == ["ada@example.invalid"])
    }

    /// Three answers, and a caller needs all three: nothing recorded, recorded as absent,
    /// and bytes.
    @Test("an avatar reads back by address, case-insensitively, and says when it is missing")
    func avatarsReadBackByAddress() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try await store.upsert(
            avatar: AvatarRecord(email: "Ada@Example.invalid", data: bytes, mime: "image/png", fetchedAt: 100),
            accountId: 1
        )
        try await store.upsert(
            avatar: AvatarRecord(email: "nobody@example.invalid", missing: true, fetchedAt: 100),
            accountId: 1
        )

        let ada = try #require(try await store.avatar(for: "ada@example.INVALID"))
        #expect(ada.data == bytes)
        #expect(ada.mime == "image/png")
        #expect(!ada.missing)

        #expect(try await store.avatar(for: "nobody@example.invalid")?.missing == true)
        #expect(try await store.avatar(for: "never-asked@example.invalid") == nil)
    }

    /// The key the writer stores is the key the work list retires and the reader finds. SQLite
    /// built without ICU folds ASCII only, and Swift folds all of Unicode; mixing the two once
    /// kept `Ö@` on the work list forever and let the Kelvin sign's address (U+212A, which
    /// Swift folds to `k`) overwrite `kevin@`'s photo.
    @Test("an address with a non-ASCII capital is stored under the key the work list and the reader use")
    func avatarKeysFoldOneWay() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let kelvin = "\u{212A}evin@example.invalid"
        try await store.upsert(
            envelopes: ["Ö@example.invalid", kelvin, "kevin@example.invalid"].enumerated().map { offset, email in
                Seed.envelope(
                    remoteId: Int64(offset) + 1,
                    sentAt: 100 + Int64(offset),
                    addresses: [EnvelopeAddress(kind: .from, email: email)]
                )
            }
        )
        let photo = AvatarRecord(email: "kevin@example.invalid", data: Data([1]), mime: "image/png", fetchedAt: 100)
        try await store.upsert(avatar: photo, accountId: 1)
        for email in ["Ö@example.invalid", kelvin] {
            try await store.upsert(avatar: AvatarRecord(email: email, missing: true, fetchedAt: 100), accountId: 1)
        }

        let needing = try await store.sendersNeedingAvatars(
            accountId: 1,
            staleBefore: 0,
            retryMissingBefore: 0,
            limit: 25
        )
        #expect(needing.isEmpty)
        #expect(try await store.avatar(for: "Ö@example.invalid")?.missing == true)
        #expect(try await store.avatar(for: kelvin)?.missing == true)
        #expect(try await store.avatar(for: "kevin@example.invalid") == photo)
    }
}
