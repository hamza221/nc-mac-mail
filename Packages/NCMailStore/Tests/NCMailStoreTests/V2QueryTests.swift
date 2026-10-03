// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// One query test per v2 table, as the brief demands: not coverage theatre, but proof that
/// each DAO's conflict target, ordering and replace semantics do what their comments claim.
@Suite("v2 queries")
struct V2QueryTests {
    // MARK: Login

    @Test func ensureLoginInsertsOnceAndFlagsRoundTrip() async throws {
        let store = try MailStore.inMemory()
        let first = try await store.ensureLogin(Seed.identity)
        let second = try await store.ensureLogin(Seed.identity)
        #expect(first.id != nil)
        #expect(first.id == second.id)

        var flagged = second
        flagged.disableSnooze = true
        flagged.attachmentSizeLimit = 104_857_600
        flagged.flagsFetchedAt = 42
        try await store.update(login: flagged)

        let read = try #require(try await store.login(for: Seed.identity))
        #expect(read.disableSnooze == true)
        #expect(read.attachmentSizeLimit == 104_857_600)
        // Undiscovered flags stay nil, which the UI reads as "feature on".
        #expect(read.allowNewAccounts == nil)
    }

    // MARK: Account v2 columns

    @Test func accountSettingsColumnsSurviveTheUpsert() async throws {
        let store = try MailStore.inMemory()
        var write = Seed.account()
        write.editorMode = "richtext"
        write.signatureAboveQuote = true
        write.trashRetentionDays = 30
        write.sieveEnabled = true
        write.provisioningId = 9
        let rows = try await store.upsert(accounts: [write])
        let account = try #require(rows.first)
        #expect(account.editorMode == "richtext")
        #expect(account.signatureAboveQuote)
        #expect(account.trashRetentionDays == 30)
        #expect(account.sieveEnabled)
        #expect(account.provisioningId == 9)
        #expect(!account.isDelegated)
    }

    // MARK: Aliases

    @Test func aliasesAreReplacedNotMerged() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.replaceAliases(
            [
                AliasRecord(accountId: 1, remoteId: 1, email: "old@example.invalid"),
                AliasRecord(accountId: 1, remoteId: 2, email: "kept@example.invalid"),
            ],
            accountId: 1
        )
        try await store.replaceAliases(
            [AliasRecord(accountId: 1, remoteId: 2, email: "kept@example.invalid", name: "Kept")],
            accountId: 1
        )
        let aliases = try await store.aliases(accountId: 1)
        #expect(aliases.map(\.remoteId) == [2])
        #expect(aliases.first?.name == "Kept")
    }

    // MARK: Drafts

    @Test func aDraftRoundTripsWithRecipientsAndAttachments() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)

        var draft = try await store.insert(
            draft: DraftRecord(accountId: 1, subject: "Hello", createdAt: 10, updatedAt: 10)
        )
        let draftId = try #require(draft.id)

        draft.subject = "Hello again"
        draft.updatedAt = 20
        try await store.update(draft: draft)

        try await store.replaceRecipients(
            [
                DraftRecipientRecord(draftId: draftId, kind: "to", position: 0, email: "b@example.invalid", label: "B"),
                DraftRecipientRecord(draftId: draftId, kind: "cc", position: 0, email: "c@example.invalid"),
            ],
            draftId: draftId
        )
        var attachment = try await store.insert(
            draftAttachment: DraftAttachmentRecord(draftId: draftId, fileName: "a.pdf", size: 3)
        )
        attachment.remoteAttachmentId = 77
        try await store.update(draftAttachment: attachment)

        let read = try #require(try await store.draft(id: draftId))
        #expect(read.subject == "Hello again")
        #expect(
            try await store.recipients(draftId: draftId).map(\.email) == ["c@example.invalid", "b@example.invalid"])
        #expect(try await store.attachments(draftId: draftId).first?.remoteAttachmentId == 77)

        try await store.deleteDraft(id: draftId)
        #expect(try await store.drafts(accountId: 1).isEmpty)
        #expect(try await store.recipients(draftId: draftId).isEmpty)
        #expect(try await store.attachments(draftId: draftId).isEmpty)
    }

    @Test func draftsListNewestEditFirst() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.insert(draft: DraftRecord(accountId: 1, subject: "old", createdAt: 1, updatedAt: 1))
        try await store.insert(draft: DraftRecord(accountId: 1, subject: "new", createdAt: 2, updatedAt: 9))
        #expect(try await store.drafts(accountId: 1).map(\.subject) == ["new", "old"])
    }

    // MARK: Outbox

    @Test func theOutboxIsReplacedAndOrderedBySendTime() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.replaceOutbox(
            [OutboxMessageRecord(accountId: 1, remoteId: 9, subject: "stale", syncedAt: 1)], accountId: 1)
        try await store.replaceOutbox(
            [
                OutboxMessageRecord(accountId: 1, remoteId: 1, subject: "whenever", syncedAt: 2),
                OutboxMessageRecord(accountId: 1, remoteId: 2, subject: "soon", sendAt: 100, syncedAt: 2),
                OutboxMessageRecord(accountId: 1, remoteId: 3, subject: "later", sendAt: 200, syncedAt: 2),
            ],
            accountId: 1
        )
        let subjects = try await store.outboxMessages().map(\.subject)
        #expect(subjects == ["soon", "later", "whenever"])
    }

    // MARK: Preferences

    @Test func aPreferenceOverwritesItsOwnKey() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.setPreference(key: "sort-order", value: "newest", loginId: loginId, fetchedAt: 1)
        try await store.setPreference(key: "sort-order", value: "oldest", loginId: loginId, fetchedAt: 2)
        #expect(try await store.preferenceValue(key: "sort-order", loginId: loginId) == "oldest")
        #expect(try await store.preferenceValue(key: "layout-mode", loginId: loginId) == nil)
    }

    // MARK: Text blocks

    @Test func textBlockSharesHangOffTheirBlock() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let blocks = try await store.replaceTextBlocks(
            [
                TextBlockRecord(loginId: loginId, remoteId: 1, title: "Mine", content: "a"),
                TextBlockRecord(
                    loginId: loginId, remoteId: 2, title: "Theirs", content: "b", isShared: true, ownerId: "bob"),
            ],
            loginId: loginId
        )
        let mineId = try #require(blocks.first?.id)
        try await store.replaceTextBlockShares(
            [TextBlockShareRecord(textBlockId: mineId, shareWith: "friends", type: "group")],
            textBlockId: mineId
        )
        // Own blocks list before shared ones.
        #expect(try await store.textBlocks(loginId: loginId).map(\.title) == ["Mine", "Theirs"])
        #expect(try await store.textBlockShares(textBlockId: mineId).map(\.shareWith) == ["friends"])

        // Replacing the blocks cascades the shares: no orphans, no stale share rows.
        try await store.replaceTextBlocks([], loginId: loginId)
        #expect(try await store.textBlockShares(textBlockId: mineId).isEmpty)
    }

    // MARK: Quick actions

    @Test func quickActionStepsComeBackInExecutionOrder() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let actions = try await store.replaceQuickActions(
            [QuickActionRecord(accountId: 1, remoteId: 4, name: "Sweep")],
            accountId: 1
        )
        let actionId = try #require(actions.first?.id)
        try await store.replaceQuickActionSteps(
            [
                QuickActionStepRecord(
                    quickActionId: actionId, remoteId: 2, name: "moveThread", position: 1, mailboxRemoteId: 1010),
                QuickActionStepRecord(quickActionId: actionId, remoteId: 1, name: "markAsRead", position: 0),
            ],
            quickActionId: actionId
        )
        let steps = try await store.quickActionSteps(quickActionId: actionId)
        #expect(steps.map(\.name) == ["markAsRead", "moveThread"])
        #expect(steps.last?.mailboxRemoteId == 1010)
    }

    // MARK: Trusted senders and internal addresses

    @Test func senderTrustMatchesIndividualsAndDomains() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.replaceTrustedSenders(
            [
                TrustedSenderRecord(loginId: loginId, email: "Ada@Example.invalid", type: "individual"),
                TrustedSenderRecord(loginId: loginId, email: "corp.invalid", type: "domain"),
            ],
            loginId: loginId
        )
        #expect(try await store.trustedSenders(loginId: loginId).count == 2)
        #expect(try await store.isSenderTrusted(email: "ada@example.invalid", loginId: loginId))
        #expect(try await store.isSenderTrusted(email: "anyone@CORP.invalid", loginId: loginId))
        #expect(!(try await store.isSenderTrusted(email: "stranger@elsewhere.invalid", loginId: loginId)))
    }

    @Test func internalAddressesMatchTheSameWay() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.replaceInternalAddresses(
            [InternalAddressRecord(loginId: loginId, address: "example.invalid", type: "domain")],
            loginId: loginId
        )
        #expect(try await store.internalAddresses(loginId: loginId).count == 1)
        #expect(try await store.isAddressInternal(email: "ada@example.invalid", loginId: loginId))
        #expect(!(try await store.isAddressInternal(email: "ada@external.invalid", loginId: loginId)))
    }

    // MARK: Delegation

    @Test func delegationsAreScopedToTheirAccount() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(accounts: [Seed.account(remoteId: 2)])
        try await store.replaceDelegations(
            [DelegationRecord(accountId: 1, userId: "bob", displayName: "Bob")], accountId: 1)
        #expect(try await store.delegations(accountId: 1).map(\.userId) == ["bob"])
        #expect(try await store.delegations(accountId: 2).isEmpty)
    }

    // MARK: S/MIME certificates

    @Test func smimeCertificatesRoundTrip() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.replaceSmimeCertificates(
            [
                SmimeCertificateRecord(
                    loginId: loginId,
                    remoteId: 3,
                    emailAddress: "ada@one.example.invalid",
                    hasPrivateKey: true,
                    notAfter: 4_102_444_800,
                    canSign: true,
                    canEncrypt: true
                )
            ],
            loginId: loginId
        )
        let certificate = try #require(try await store.smimeCertificates(loginId: loginId).first)
        #expect(certificate.hasPrivateKey)
        #expect(certificate.canSign && certificate.canEncrypt)
        #expect(certificate.notAfter == 4_102_444_800)
    }

    // MARK: Sieve

    @Test func sieveStateIsOneRowPerAccount() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(sieveState: SieveStateRecord(accountId: 1, sieveEnabled: false, fetchedAt: 1))
        try await store.upsert(
            sieveState: SieveStateRecord(
                accountId: 1,
                sieveEnabled: true,
                sieveHost: "mail.example.invalid",
                sievePort: 4190,
                script: "# managed",
                filtersJSON: "[]",
                outOfOfficeJSON: "{\"enabled\":false}",
                fetchedAt: 2
            )
        )
        let state = try #require(try await store.sieveState(accountId: 1))
        #expect(state.sieveEnabled)
        #expect(state.sievePort == 4190)
        #expect(state.fetchedAt == 2)
        let rows = try await store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sieveState") }
        #expect(rows == 1)
    }

    // MARK: Server results

    @Test func aServerResultOverwritesItsKeyAndExpires() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: "threadSummary", key: "42", payloadJSON: "{\"v\":1}", fetchedAt: 1)
        )
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: "threadSummary", key: "42", payloadJSON: "{\"v\":2}", fetchedAt: 2)
        )
        let result = try #require(try await store.serverResult(kind: "threadSummary", key: "42", loginId: loginId))
        #expect(result.payloadJSON == "{\"v\":2}")

        try await store.deleteServerResults(kind: "threadSummary", olderThan: 3, loginId: loginId)
        #expect(try await store.serverResult(kind: "threadSummary", key: "42", loginId: loginId) == nil)
    }

    @Test func recipientSuggestionsAreReplacedPerTerm() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.replaceRecipientSuggestions(
            [
                RecipientSuggestionRecord(
                    loginId: loginId, term: "a", position: 9, email: "stale@example.invalid", fetchedAt: 1)
            ],
            term: "a",
            loginId: loginId
        )
        try await store.replaceRecipientSuggestions(
            [
                RecipientSuggestionRecord(
                    loginId: loginId, term: "a", position: 0, email: "first@example.invalid", fetchedAt: 2),
                RecipientSuggestionRecord(
                    loginId: loginId, term: "a", position: 0, email: "second@example.invalid", fetchedAt: 2),
            ],
            term: "a",
            loginId: loginId
        )
        let suggestions = try await store.recipientSuggestions(term: "a", loginId: loginId)
        // The DAO renumbers positions from the array order, so a sloppy caller cannot collide.
        #expect(suggestions.map(\.email) == ["first@example.invalid", "second@example.invalid"])
        #expect(suggestions.map(\.position) == [0, 1])
        #expect(try await store.recipientSuggestions(term: "b", loginId: loginId).isEmpty)
    }

    @Test func filesListingsAndSmartPickerResultsOverwriteTheirKeys() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)

        try await store.upsert(
            filesListing: FilesListingRecord(loginId: loginId, path: "/Mail", entriesJSON: "[]", fetchedAt: 1))
        try await store.upsert(
            filesListing: FilesListingRecord(loginId: loginId, path: "/Mail", entriesJSON: "[{}]", fetchedAt: 2))
        let listing = try #require(try await store.filesListing(path: "/Mail", loginId: loginId))
        #expect(listing.entriesJSON == "[{}]")

        try await store.upsert(
            smartPickerResult: SmartPickerResultRecord(
                loginId: loginId, providerId: "files", term: "plan", payloadJSON: "[1]", fetchedAt: 1)
        )
        try await store.upsert(
            smartPickerResult: SmartPickerResultRecord(
                loginId: loginId, providerId: "files", term: "plan", payloadJSON: "[2]", fetchedAt: 2)
        )
        let picker = try #require(
            try await store.smartPickerResult(providerId: "files", term: "plan", loginId: loginId))
        #expect(picker.payloadJSON == "[2]")
    }

    // MARK: Address books and contacts

    @Test func syncingAddressBooksPreservesTheMirrorsOwnColumns() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [
                AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal"),
                AddressBookRecord(loginId: loginId, url: "/dav/books/work/", displayName: "Work"),
            ],
            loginId: loginId
        )
        let personalId = try #require(books.first(where: { $0.url == "/dav/books/personal/" })?.id)
        try await store.setAddressBookSyncToken("token-1", lastSyncAt: 5, addressBookId: personalId)
        try await store.setAddressBookEnabled(false, addressBookId: personalId)

        // A relisting renames the book and drops the other; the bookkeeping survives.
        let after = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "People")],
            loginId: loginId
        )
        #expect(after.count == 1)
        let personal = try #require(after.first)
        #expect(personal.id == personalId)
        #expect(personal.displayName == "People")
        #expect(personal.syncToken == "token-1")
        #expect(personal.lastSyncAt == 5)
        #expect(!personal.isEnabled)
    }

    @Test func aContactKeepsItsLocalIdAcrossUpdates() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
            loginId: loginId
        )
        let bookId = try #require(books.first?.id)

        let inserted = try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/dav/books/personal/ada.vcf",
                etag: "\"1\"",
                uid: "uid-ada",
                vcard: "BEGIN:VCARD\nEND:VCARD",
                displayName: "Ada Lovelace",
                syncedAt: 1
            ),
            emails: [
                ContactEmailRecord(contactId: 0, position: 0, email: "ada@one.example.invalid", type: "WORK"),
                ContactEmailRecord(contactId: 0, position: 1, email: "ada@home.example.invalid", type: "HOME"),
            ],
            phones: [ContactPhoneRecord(contactId: 0, position: 0, number: "+44 20 1")]
        )
        let contactId = try #require(inserted.id)

        let updated = try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/dav/books/personal/ada.vcf",
                etag: "\"2\"",
                uid: "uid-ada",
                vcard: "BEGIN:VCARD\nEND:VCARD",
                displayName: "Ada King",
                organization: "Analytical Engines",
                syncedAt: 2
            ),
            emails: [ContactEmailRecord(contactId: 0, position: 0, email: "ada@one.example.invalid")]
        )
        #expect(updated.id == contactId)

        let read = try #require(try await store.contact(id: contactId))
        #expect(read.displayName == "Ada King")
        #expect(read.etag == "\"2\"")
        // Children are rewritten, not merged: the HOME address and the phone are gone.
        #expect(try await store.contactEmails(contactId: contactId).map(\.email) == ["ada@one.example.invalid"])
        #expect(try await store.contactPhones(contactId: contactId).isEmpty)
    }

    @Test func contactLookupByEmailHonoursTheBookToggle() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
            loginId: loginId
        )
        let bookId = try #require(books.first?.id)
        try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/c.vcf",
                uid: "u1",
                vcard: "BEGIN:VCARD\nEND:VCARD",
                displayName: "Ada",
                syncedAt: 1
            ),
            emails: [ContactEmailRecord(contactId: 0, position: 0, email: "Ada@One.example.invalid")]
        )

        #expect(try await store.contacts(withEmail: "ada@one.example.invalid").count == 1)
        try await store.setAddressBookEnabled(false, addressBookId: bookId)
        #expect(try await store.contacts(withEmail: "ada@one.example.invalid").isEmpty)
    }

    @Test func groupMembersResolveThroughUids() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
            loginId: loginId
        )
        let bookId = try #require(books.first?.id)

        // The group arrives before one of its members, which is CardDAV's normal weather.
        let group = try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/g.vcf",
                uid: "uid-group",
                vcard: "BEGIN:VCARD\nKIND:group\nEND:VCARD",
                displayName: "Team",
                isGroup: true,
                syncedAt: 1
            ),
            memberUids: ["uid-ada", "uid-absent"]
        )
        let groupId = try #require(group.id)
        #expect(try await store.members(ofGroup: groupId).isEmpty)

        try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/a.vcf",
                uid: "uid-ada",
                vcard: "BEGIN:VCARD\nEND:VCARD",
                displayName: "Ada",
                syncedAt: 2
            )
        )
        #expect(try await store.members(ofGroup: groupId).map(\.displayName) == ["Ada"])
    }

    @Test func contactSearchIndexesAndForgetsWithItsRow() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
            loginId: loginId
        )
        let bookId = try #require(books.first?.id)
        let contact = try await store.upsert(
            contact: ContactRecord(
                addressBookId: bookId,
                href: "/a.vcf",
                uid: "u1",
                vcard: "BEGIN:VCARD\nEND:VCARD",
                displayName: "Ada Lovelace",
                organization: "Analytical Engines",
                syncedAt: 1
            ),
            emails: [ContactEmailRecord(contactId: 0, position: 0, email: "ada@one.example.invalid")]
        )
        let contactId = try #require(contact.id)

        let byName = try await store.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT rowid FROM contactSearch WHERE contactSearch MATCH ?", arguments: ["lovelace"])
        }
        #expect(byName == [contactId])
        let byEmail = try await store.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT rowid FROM contactSearch WHERE contactSearch MATCH ?", arguments: ["ada"])
        }
        #expect(byEmail == [contactId])

        // The delete goes through the trigger: no Swift code mentions the index (ADR-0024).
        try await store.deleteContact(addressBookId: bookId, href: "/a.vcf")
        let remaining = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM contactSearch") ?? -1
        }
        #expect(remaining == 0)
    }

    // MARK: Calendars

    @Test func calendarsListInPositionOrder() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        try await store.replaceCalendars(
            [
                CalendarRecord(
                    loginId: loginId, url: "/cal/b/", displayName: "Tasks", supportsEvents: false, supportsTasks: true,
                    position: 1, fetchedAt: 1),
                CalendarRecord(loginId: loginId, url: "/cal/a/", displayName: "Personal", position: 0, fetchedAt: 1),
            ],
            loginId: loginId
        )
        let calendars = try await store.calendars(loginId: loginId)
        #expect(calendars.map(\.displayName) == ["Personal", "Tasks"])
        #expect(calendars.last?.supportsTasks == true)
    }

    // MARK: Teams

    @Test func teamMembersHangOffTheirTeam() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let teams = try await store.replaceTeams(
            [TeamRecord(loginId: loginId, remoteId: "circle-abc", displayName: "Crew", fetchedAt: 1)],
            loginId: loginId
        )
        let teamId = try #require(teams.first?.id)
        try await store.replaceTeamMembers(
            [
                TeamMemberRecord(teamId: teamId, userId: "bob", displayName: "Bob"),
                TeamMemberRecord(teamId: teamId, userId: "ada", displayName: "Ada"),
            ],
            teamId: teamId
        )
        #expect(try await store.teams(loginId: loginId).first?.remoteId == "circle-abc")
        #expect(try await store.teamMembers(teamId: teamId).map(\.userId) == ["ada", "bob"])

        // Replacing the team list cascades the members.
        try await store.replaceTeams([], loginId: loginId)
        #expect(try await store.teamMembers(teamId: teamId).isEmpty)
    }

    // MARK: Snooze

    @Test func snoozeIsOneRowPerMessageAndTheSweepFindsDueOnes() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [
            Seed.envelope(remoteId: 1, sentAt: 100), Seed.envelope(remoteId: 2, sentAt: 200),
        ])

        try await store.setSnooze(until: 50, messageId: 1)
        try await store.setSnooze(until: 500, messageId: 1)
        try await store.setSnooze(until: 60, messageId: 2)

        #expect(try await store.snoozeUntil(messageId: 1) == 500)
        #expect(try await store.dueSnoozes(before: 100).map(\.messageId) == [2])

        try await store.clearSnooze(messageId: 2)
        #expect(try await store.snoozeUntil(messageId: 2) == nil)
        // Clearing a message that was never snoozed is a no-op, not an error.
        try await store.clearSnooze(messageId: 2)
    }

    // MARK: Observation

    /// The v2 tables are rowid tables so that observations fire (ADR-0025); one live proof
    /// over a representative DAO, in the exact shape `ObservationTests` uses for v1.
    @Test func aBackgroundDraftWriteReachesAnObserver() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.insert(draft: DraftRecord(accountId: 1, subject: "first", createdAt: 1, updatedAt: 1))

        var received: [[String?]] = []
        for try await drafts in store.observeDrafts(accountId: 1) {
            received.append(drafts.map(\.subject))
            if received.count == 1 {
                _ = try await Task.detached {
                    try await store.insert(
                        draft: DraftRecord(accountId: 1, subject: "second", createdAt: 2, updatedAt: 2))
                }.value
            } else {
                break
            }
        }

        #expect(received == [["first"], ["second", "first"]])
    }
}
