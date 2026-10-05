// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Login cascade")
struct LoginCascadeTests {
    /// Every table, counted, after a sign-out — the v2 version of
    /// `StoreWriteTests/deletingAnAccountLeavesNothingBehind`.
    ///
    /// A login is two cascade roots (ADR-0079): the `account` rows carry the identity inline
    /// since v1, and the `login` row anchors everything instance-scoped. `deleteLogin` removes
    /// both in one transaction; this test seeds a row into every table that can hang off
    /// either, including both FTS indexes, and then counts them all. `avatar` and `meta` stay
    /// out of the list the way the account test leaves them out: an avatar is a picture of a
    /// person shared across servers (ADR-0033), and `meta` is app state.
    @Test func deletingALoginLeavesNothingBehind() async throws {
        let store = try MailStore.inMemory()

        // The mail side, exactly as the account cascade test builds it.
        try await Seed.base(store)
        try await store.upsert(
            envelopes: (1...3).map {
                Seed.envelope(
                    remoteId: $0,
                    sentAt: 100 + $0,
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "a@example.invalid", label: "A"),
                        EnvelopeAddress(kind: .to, email: "b@example.invalid", label: "B"),
                    ]
                )
            }
        )
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1,
                plainBody: "text",
                attachments: [AttachmentWrite(attachmentId: "2", fileName: "a.pdf")]
            ),
            for: 1
        )
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

        // The account-scoped v2 tables.
        try await store.replaceAliases(
            [AliasRecord(accountId: 1, remoteId: 7, email: "ada@one.example.invalid")], accountId: 1)
        let aliasId = try #require(try await store.aliases(accountId: 1).first?.id)
        let draft = try await store.insert(
            draft: DraftRecord(accountId: 1, aliasId: aliasId, subject: "Hello", createdAt: 1, updatedAt: 1)
        )
        let draftId = try #require(draft.id)
        try await store.replaceRecipients(
            [DraftRecipientRecord(draftId: draftId, kind: "to", position: 0, email: "b@example.invalid")],
            draftId: draftId
        )
        try await store.insert(draftAttachment: DraftAttachmentRecord(draftId: draftId, fileName: "a.pdf"))
        try await store.replaceOutbox(
            [OutboxMessageRecord(accountId: 1, remoteId: 1, subject: "Queued", syncedAt: 1)], accountId: 1)
        let actions = try await store.replaceQuickActions(
            [QuickActionRecord(accountId: 1, remoteId: 1, name: "Sweep")], accountId: 1)
        let actionId = try #require(actions.first?.id)
        try await store.replaceQuickActionSteps(
            [QuickActionStepRecord(quickActionId: actionId, remoteId: 1, name: "markAsRead", position: 0)],
            quickActionId: actionId
        )
        try await store.replaceDelegations([DelegationRecord(accountId: 1, userId: "bob")], accountId: 1)
        try await store.upsert(sieveState: SieveStateRecord(accountId: 1, sieveEnabled: true, fetchedAt: 1))
        try await store.setSnooze(until: 9999, messageId: 1)

        // The login-scoped tables.
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.setPreference(key: "sort-order", value: "newest", loginId: loginId, fetchedAt: 1)
        let blocks = try await store.replaceTextBlocks(
            [TextBlockRecord(loginId: loginId, remoteId: 1, title: "Sig", content: "Regards")],
            loginId: loginId
        )
        let blockId = try #require(blocks.first?.id)
        try await store.replaceTextBlockShares(
            [TextBlockShareRecord(textBlockId: blockId, shareWith: "friends", type: "group")],
            textBlockId: blockId
        )
        try await store.replaceTrustedSenders(
            [TrustedSenderRecord(loginId: loginId, email: "a@example.invalid", type: "individual")],
            loginId: loginId
        )
        try await store.replaceInternalAddresses(
            [InternalAddressRecord(loginId: loginId, address: "example.invalid", type: "domain")],
            loginId: loginId
        )
        try await store.replaceSmimeCertificates(
            [SmimeCertificateRecord(loginId: loginId, remoteId: 1, emailAddress: "ada@one.example.invalid")],
            loginId: loginId
        )
        try await store.upsert(
            serverResult: ServerResultRecord(loginId: loginId, kind: "quota", key: "1", payloadJSON: "{}", fetchedAt: 1)
        )
        try await store.replaceRecipientSuggestions(
            [
                RecipientSuggestionRecord(
                    loginId: loginId, term: "b", position: 0, email: "b@example.invalid", fetchedAt: 1)
            ],
            term: "b",
            loginId: loginId
        )
        try await store.upsert(
            filesListing: FilesListingRecord(loginId: loginId, path: "/", entriesJSON: "[]", fetchedAt: 1))
        try await store.upsert(
            smartPickerResult: SmartPickerResultRecord(
                loginId: loginId, providerId: "files", term: "a", payloadJSON: "[]", fetchedAt: 1)
        )
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
            loginId: loginId
        )
        let bookId = try #require(books.first?.id)
        try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/dav/books/personal/ada.vcf",
                uid: "uid-ada",
                vcard: "BEGIN:VCARD\nEND:VCARD",
                displayName: "Ada",
                syncedAt: 1
            ),
            emails: [ContactEmailRecord(contactId: 0, position: 0, email: "ada@one.example.invalid")],
            phones: [ContactPhoneRecord(contactId: 0, position: 0, number: "+1")],
            memberUids: ["uid-ada"]
        )
        try await store.replaceCalendars(
            [CalendarRecord(loginId: loginId, url: "/dav/cal/personal/", fetchedAt: 1)], loginId: loginId)
        let teams = try await store.replaceTeams(
            [TeamRecord(loginId: loginId, remoteId: "circle-1", displayName: "Crew", fetchedAt: 1)],
            loginId: loginId
        )
        let teamId = try #require(teams.first?.id)
        try await store.replaceTeamMembers([TeamMemberRecord(teamId: teamId, userId: "bob")], teamId: teamId)

        let tables = [
            "account", "mailbox", "message", "messageAddress", "messageBody", "attachment",
            "tag", "messageTag", "pendingOperation", "messageSearch",
            "login", "alias", "draft", "draftRecipient", "draftAttachment", "outboxMessage",
            "preference", "textBlock", "textBlockShare", "quickAction", "quickActionStep",
            "trustedSender", "internalAddress", "delegation", "smimeCertificate", "sieveState",
            "serverResult", "recipientSuggestion", "filesListing", "smartPickerResult",
            "addressBook", "contact", "contactEmail", "contactPhone", "contactGroupMember",
            "contactSearch", "calendar", "team", "teamMember", "snooze",
        ]

        // The seeding above has to have actually reached every table, or the zeros below
        // prove nothing.
        let before = try await counts(in: store, tables: tables)
        for (table, count) in before.sorted(by: { $0.key < $1.key }) {
            #expect(count > 0, "\(table) was never seeded, so this test does not cover it")
        }

        try await store.deleteLogin(Seed.identity)

        let after = try await counts(in: store, tables: tables)
        for (table, count) in after.sorted(by: { $0.key < $1.key }) {
            #expect(count == 0, "\(table) still has \(count) rows after the login was deleted")
        }
    }

    /// Two logins in one mirror: deleting one must not touch the other's rows. The counter
    /// to a cascade test that only ever empties the whole file.
    @Test func deletingOneLoginLeavesTheOtherWhole() async throws {
        let store = try MailStore.inMemory()
        let other = ServerIdentity(serverURL: "https://two.example.invalid/", loginName: "grace")

        for identity in [Seed.identity, other] {
            let login = try await store.ensureLogin(identity)
            let loginId = try #require(login.id)
            try await store.upsert(accounts: [Seed.account(identity: identity)])
            try await store.setPreference(key: "sort-order", value: "newest", loginId: loginId, fetchedAt: 1)
            let books = try await store.syncAddressBooks(
                [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
                loginId: loginId
            )
            let bookId = try #require(books.first?.id)
            try await store.upsert(
                contact: ContactRecord(
                    addressBookId: bookId,
                    href: "/dav/books/personal/c.vcf",
                    uid: "uid-\(identity.loginName)",
                    vcard: "BEGIN:VCARD\nEND:VCARD",
                    displayName: identity.loginName,
                    syncedAt: 1
                )
            )
        }

        try await store.deleteLogin(Seed.identity)

        let survivor = try #require(try await store.login(for: other))
        let survivorId = try #require(survivor.id)
        #expect(try await store.accounts(identity: other).count == 1)
        #expect(try await store.preferenceValue(key: "sort-order", loginId: survivorId) == "newest")
        let books = try await store.addressBooks(loginId: survivorId)
        #expect(books.count == 1)
        let bookId = try #require(books.first?.id)
        #expect(try await store.contacts(addressBookId: bookId).count == 1)
        #expect(try await store.logins().count == 1)
    }

    private func counts(in store: MailStore, tables: [String]) async throws -> [String: Int] {
        try await store.read { db -> [String: Int] in
            var counts: [String: Int] = [:]
            for table in tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
            return counts
        }
    }
}
