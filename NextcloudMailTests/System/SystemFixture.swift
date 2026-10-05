// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// A seeded mirror for WS-42's tests: one login with one account, an Inbox and an Archive,
/// messages with Message-ID headers, and one address book with two cards and a group.
struct SystemFixture {
    static let identity = ServerIdentity(serverURL: "https://cloud.example.invalid/", loginName: "me")

    let store: MailStore
    let loginId: Int64
    let accountId: Int64
    let inboxId: Int64
    let archiveId: Int64
    let bookId: Int64
    /// Local ids by remote id.
    var messages: [Int64: Int64] = [:]
    var contacts: [String: Int64] = [:]

    static func make() async throws -> SystemFixture {
        let store = try MailStore.inMemory()
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let account = try #require(
            try await store.upsert(accounts: [
                AccountWrite(identity: identity, remoteId: 1, name: "Me", emailAddress: "me@example.invalid")
            ]).first)
        let mailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id, remoteId: 5, name: "INBOX", displayName: "Inbox", specialRole: "inbox"),
                MailboxWrite(accountId: account.id, remoteId: 6, name: "Archive", displayName: "Archive"),
            ],
            accountId: account.id)
        let inbox = try #require(mailboxes.first { $0.remoteId == 5 })
        let archive = try #require(mailboxes.first { $0.remoteId == 6 })
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "https://cloud.example.invalid/addressbooks/users/me/contacts/")],
            loginId: loginId)
        let book = try #require(books.first?.id)
        var fixture = SystemFixture(
            store: store, loginId: loginId, accountId: account.id, inboxId: inbox.id, archiveId: archive.id,
            bookId: book)
        for (name, email) in [("Ada Lovelace", "ada@example.invalid"), ("Grace Hopper", "grace@example.invalid")] {
            let saved = try await fixture.addContact(name: name, email: email)
            fixture.contacts[name] = saved
        }
        try await store.upsert(
            contact: ContactRecord(
                addressBookId: book, href: "/group.vcf", vcard: "BEGIN:VCARD\r\nEND:VCARD\r\n", displayName: "Team",
                isGroup: true, syncedAt: 0))
        return fixture
    }

    func addContact(name: String, email: String) async throws -> Int64 {
        let saved = try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId, href: "/\(email).vcf", vcard: "BEGIN:VCARD\r\nEND:VCARD\r\n",
                displayName: name, syncedAt: 0),
            emails: [ContactEmailRecord(contactId: 0, position: 0, email: email)])
        return try #require(saved.id)
    }

    /// Writes (or rewrites) one envelope and returns its local id.
    @discardableResult
    mutating func message(
        remoteId: Int64, mailboxId: Int64? = nil, header: String? = nil, subject: String = "Hello",
        sentAt: Int64 = 1_790_000_000, isSeen: Bool = false, isImportant: Bool = false,
        sender: String = "Alice"
    ) async throws -> Int64 {
        var flags = MessageFlags()
        flags.isSeen = isSeen
        flags.isImportant = isImportant
        let ids = try await store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: remoteId, mailboxId: mailboxId ?? inboxId, accountId: accountId, sentAt: sentAt,
                syncedAt: sentAt, messageId: header, subject: subject, previewText: "Preview \(remoteId)",
                flags: flags, fromEmail: "alice@example.invalid", fromLabel: sender,
                addresses: [EnvelopeAddress(kind: .from, email: "alice@example.invalid", label: sender)])
        ])
        let id = try #require(ids.first)
        messages[remoteId] = id
        return id
    }

    /// Every message, newest first, as the Spotlight feed observes them.
    func allRows() async throws -> [MessageRow] {
        try await store.messages(
            query: MessageListQuery(mailboxIds: []), view: .flat, order: .newest,
            range: 0..<SpotlightIndexer.messageLimit)
    }
}
