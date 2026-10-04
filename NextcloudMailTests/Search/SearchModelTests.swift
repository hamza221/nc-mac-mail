// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// Search from the field down to the rows, against a real mirror.
///
/// The text is written here rather than taken from `MessageListMirror`, which seeds the
/// scrubbed strings the recorder produces — every subject "Subject redacted", every sender
/// "Name redacted". That is the right fixture for a list test and useless for this one.
///
/// Nothing is mocked below `MailStore`. "Search never asks the server" is a fact about the
/// link line rather than a claim: `NCMailStore` cannot see `NCMailNet`, and this file names
/// neither a transport nor a client.
@Suite("Search")
@MainActor
struct SearchModelTests {
    struct Mirror {
        let store: MailStore
        let accountId: Int64
        let inboxId: Int64
        let archiveId: Int64
        let messageIds: [Int64]
    }

    /// One account, two mailboxes, six messages with words that overlap on purpose.
    static func seed() async throws -> Mirror {
        let store = try MailStore.inMemory()
        let identity = ServerIdentity(serverURL: "https://one.example.invalid/", loginName: "lorelai")
        let accounts = try await store.upsert(accounts: [
            AccountWrite(identity: identity, remoteId: 1, name: "Work", emailAddress: "lorelai@example.invalid")
        ])
        let account = try #require(accounts.first)
        let mailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id, remoteId: 1005, name: "INBOX", displayName: "Inbox",
                    isSubscribed: true
                ),
                MailboxWrite(
                    accountId: account.id, remoteId: 1006, name: "Archive", displayName: "Archive",
                    isSubscribed: true
                ),
                // Unsubscribed, so `upsert` leaves it unmirrored and the scope control has
                // something to say about "All Mail" (ADR-0007).
                MailboxWrite(
                    accountId: account.id, remoteId: 1007, name: "Old", displayName: "Old",
                    isSubscribed: false
                ),
            ],
            accountId: account.id
        )
        let inbox = try #require(mailboxes.first)
        let archive = try #require(mailboxes.dropFirst().first)

        let subjects = [
            "Quarterly hedgehog census",
            "Dragonfly Inn opening menu",
            "Re: the roadmap",
            "Lunch with Sookie",
            "Hedgehog rescue rota",
        ]
        var ids: [Int64] = []
        for (offset, subject) in subjects.enumerated() {
            ids += try await store.upsert(envelopes: [
                EnvelopeWrite(
                    remoteId: Int64(offset) + 1,
                    mailboxId: inbox.id,
                    accountId: account.id,
                    sentAt: 1_700_000_000 + Int64(offset),
                    syncedAt: 1_700_000_000 + Int64(offset),
                    subject: subject,
                    previewText: "Some words about \(subject.lowercased()).",
                    fromEmail: "sookie@dragonfly.invalid",
                    fromLabel: "Sookie St. James",
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "sookie@dragonfly.invalid", label: "Sookie St. James")
                    ]
                )
            ])
        }
        ids += try await store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: 100,
                mailboxId: archive.id,
                accountId: account.id,
                sentAt: 1_700_000_100,
                syncedAt: 1_700_000_100,
                subject: "Archived hedgehog paperwork",
                previewText: "Filed last spring.",
                fromEmail: "luke@diner.invalid",
                fromLabel: "Luke Danes",
                addresses: [EnvelopeAddress(kind: .from, email: "luke@diner.invalid", label: "Luke Danes")]
            )
        ])
        try await store.setEnvelopeCursor(nil, complete: true, mailboxId: inbox.id, lastSyncAt: 1)
        return Mirror(
            store: store,
            accountId: account.id,
            inboxId: inbox.id,
            archiveId: archive.id,
            messageIds: ids
        )
    }

    /// The wiring `SearchableMessageList` does: install the seam, then drive the list.
    static func wired(_ mirror: Mirror) -> (search: SearchModel, list: MessageListStore) {
        let search = SearchModel(store: mirror.store)
        let list = MessageListStore(store: mirror.store)
        list.filteredSource = search.rowSource()
        search.mailboxId = mirror.inboxId
        return (search, list)
    }

    static func show(_ search: SearchModel, _ list: MessageListStore, in mailboxId: Int64) {
        list.show(.mailbox(mailboxId), view: .flat, filter: search.filter)
    }

    // MARK: - What counts as a search

    @Test(arguments: ["", " ", "\n\t "])
    func aBlankFieldIsNotASearch(_ text: String) async throws {
        let mirror = try await Self.seed()
        let (search, _) = Self.wired(mirror)
        search.text = text
        #expect(search.filter == nil)
        #expect(search.isSearching == false)
    }

    @Test func typingReplacesTheListWithResults() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)

        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 5 })

        search.text = "hedgehog"
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 2 })
        #expect(list.presentation == .rows)
    }

    /// Prefix matching is what makes "results as you type" mean anything — but a term needs
    /// two characters (WS-32), so the first keystroke leaves the mailbox showing and the
    /// second narrows it.
    @Test func resultsNarrowFromTheSecondCharacter() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)

        for (text, expected) in [("h", 5), ("he", 2), ("hedgehog c", 2), ("hedgehog ce", 1)] {
            search.text = text
            Self.show(search, list, in: mirror.inboxId)
            #expect(await waitUntil { list.rows.count == expected }, "\(text) gave \(list.rows.count)")
        }
        search.text = "h"
        #expect(search.filter == nil)
    }

    // MARK: - Filters (WS-32)

    /// A chip with an empty field is a search: newest first, filtered.
    @Test func aChipAloneIsASearch() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        // Mark the two inbox hedgehog messages read by re-mirroring their envelopes.
        var seen = MessageFlags()
        seen.isSeen = true
        for (remoteId, subject) in [(Int64(1), "Quarterly hedgehog census"), (5, "Hedgehog rescue rota")] {
            try await mirror.store.upsert(envelopes: [
                EnvelopeWrite(
                    remoteId: remoteId,
                    mailboxId: mirror.inboxId,
                    accountId: mirror.accountId,
                    sentAt: 1_700_000_000 + remoteId - 1,
                    syncedAt: 1_700_000_100,
                    subject: subject,
                    flags: seen,
                    fromEmail: "sookie@dragonfly.invalid",
                    addresses: [EnvelopeAddress(kind: .from, email: "sookie@dragonfly.invalid")]
                )
            ])
        }
        search.flags.unreadOnly = true
        #expect(search.isSearching)
        #expect(search.filter?.search?.flags?.unreadOnly == true)
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 3 })

        search.clearFilters()
        #expect(search.filter == nil)
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 5 })
    }

    /// Changing a chip changes the filter's identity, so the list reopens its observation
    /// even though the text did not change.
    @Test func aChipChangesTheFilterUnderTheSameText() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.text = "hedgehog"
        let before = search.filter
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 2 })

        search.apply(
            parameters: SearchQuery.Parameters(subject: "rescue"),
            flags: SearchQuery.FlagFilter()
        )
        #expect(search.filter != before)
        #expect(search.activeParameterCount == 1)
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 1 })
    }

    @Test func theSheetsParametersReachTheQuery() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.scope = .allMail
        search.isParametersSheetPresented = true
        search.apply(
            parameters: SearchQuery.Parameters(from: "luke@diner.invalid"),
            flags: SearchQuery.FlagFilter()
        )
        #expect(search.isParametersSheetPresented == false)
        #expect(search.hasActiveFilters)
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 1 })
        #expect(list.rows.first?.mailboxId == mirror.archiveId)
    }

    @Test func addressSuggestionsComeFromTheMirror() async throws {
        let mirror = try await Self.seed()
        let (search, _) = Self.wired(mirror)
        #expect(await search.addressSuggestions(for: "lu").map(\.email) == ["luke@diner.invalid"])
        #expect(await search.addressSuggestions(for: "l").isEmpty)
    }

    /// A day range covers both whole days, half-open at the midnight after the end.
    @Test func dayRangeIsInclusiveOfBothDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 15)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 9)))
        let range = SearchDayRange(start: start, end: end, calendar: calendar)
        let midnight28 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28)))
        let midnight30 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 30)))
        #expect(range.sentAfter == Int64(midnight28.timeIntervalSince1970))
        // Across the DST change: 47 hours, not 48.
        #expect(range.sentBefore == Int64(midnight30.timeIntervalSince1970))
        let reopened = SearchDayRange(sentAfter: range.sentAfter, sentBefore: range.sentBefore, calendar: calendar)
        #expect(reopened == range)
    }

    @Test func clearingTheFieldReturnsToTheMailbox() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.text = "hedgehog"
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 2 })

        // Which is what Escape does to a `.searchable` field.
        search.text = ""
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 5 })
    }

    @Test func aQueryThatMatchesNothingShowsTheNoResultsScreen() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.text = "aardvark"
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.presentation == .noResults("aardvark") })
        #expect(list.rows.isEmpty)
    }

    // MARK: - Scope

    @Test func allMailSpansMailboxes() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.text = "hedgehog"

        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 2 })

        search.scope = .allMail
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 3 })
        #expect(list.rows.contains { $0.mailboxId == mirror.archiveId })
    }

    /// Selecting another mailbox has to move the `.mailbox` scope with it, or search keeps
    /// answering about the folder the user left.
    @Test func mailboxScopeFollowsTheSelection() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.text = "hedgehog"
        search.mailboxId = mirror.archiveId

        Self.show(search, list, in: mirror.archiveId)
        #expect(await waitUntil { list.rows.count == 1 })
    }

    // MARK: - The window

    @Test func theWindowGrowsUnderASearch() async throws {
        let mirror = try await Self.seed()
        let (search, list) = Self.wired(mirror)
        search.text = "hedgehog"
        Self.show(search, list, in: mirror.inboxId)
        #expect(await waitUntil { list.rows.count == 2 })
        // Two rows is short of the initial window, so the list knows it has the tail and
        // does not ask for more.
        #expect(list.hasMore == false)
        list.loadMore()
        #expect(list.rows.count == 2)
    }

    // MARK: - Commands

    @Test func theCommandsMoveFocusAndWidenTheScope() async throws {
        let mirror = try await Self.seed()
        let (search, _) = Self.wired(mirror)
        let before = search.focusRequests

        search.requestFocus()
        #expect(search.focusRequests == before + 1)

        search.searchAllMail()
        #expect(search.scope == .allMail)
        #expect(search.focusRequests == before + 2)
    }

    // MARK: - Coverage

    @Test func coverageSaysHowMuchOfTheMirrorIsSearchable() async throws {
        let mirror = try await Self.seed()
        let (search, _) = Self.wired(mirror)
        search.scope = .allMail
        search.observeCoverage()
        #expect(await waitUntil { search.coverage?.totalMessages == 6 })

        let partial = try #require(search.coverage)
        #expect(partial.indexedMessages == 0)
        #expect(partial.isComplete == false)
        // The one unsubscribed mailbox, which is what the scope control says out loud.
        #expect(partial.unmirroredMailboxes == 1)

        for id in mirror.messageIds {
            try await mirror.store.upsert(
                body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: true, html: "<p>Body \(id)</p>"),
                for: id
            )
        }
        #expect(await waitUntil { search.coverage?.isComplete == true })
    }

    /// The footer is on screen only while it has something to say, which is the difference
    /// between honest and noisy.
    @Test func theFooterSaysSomethingOnlyMidBackfillAndOnlyWhileSearching() async throws {
        let mirror = try await Self.seed()
        let (search, _) = Self.wired(mirror)
        search.scope = .allMail
        search.observeCoverage()
        #expect(await waitUntil { search.coverage?.totalMessages == 6 })

        // Nothing typed, so nothing to be honest about yet.
        #expect(search.coverageSummary == nil)
        #expect(search.unmirroredSummary == nil)

        search.text = "hedgehog"
        #expect(search.coverageSummary == "Searching 0 of 6 downloaded messages.")
        #expect(search.unmirroredSummary == "One mailbox is not downloaded, so it is not searched.")

        // "This mailbox" is one folder, so the note about the folders it skips does not apply.
        search.scope = .mailbox
        #expect(await waitUntil { search.coverage?.totalMessages == 5 })
        #expect(search.unmirroredSummary == nil)

        for id in mirror.messageIds {
            try await mirror.store.upsert(
                body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: true, html: "<p>Body \(id)</p>"),
                for: id
            )
        }
        // Once every body is indexed the footer takes itself off screen.
        #expect(await waitUntil { search.coverageSummary == nil })
    }
}
