// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import SwiftUI
import Testing

@testable import NextcloudMail

/// Clicking a contact in the list opens it: the selection picks the detail pane, and the pane
/// loads the card it was given.
@Suite("Contacts detail column")
@MainActor
struct ContactsDetailTests {
    private static let identity = ServerIdentity(serverURL: "https://contacts.example.invalid/", loginName: "me")
    private static let sessionId = "session"

    private func browser(_ store: MailStore) -> ContactsBrowser {
        ContactsBrowser(store: store, queue: { _ in nil })
    }

    @Test func nothingSelectedShowsThePlaceholder() throws {
        let browser = browser(try MailStore.inMemory())
        #expect(browser.detailPane(sessionId: Self.sessionId) == .nothing)
    }

    @Test func oneSelectedContactOpensThatContact() throws {
        let browser = browser(try MailStore.inMemory())
        browser.selection = [7]
        #expect(browser.detailPane(sessionId: Self.sessionId) == .contact(7))
    }

    @Test func severalSelectedContactsShowTheBatchPane() throws {
        let browser = browser(try MailStore.inMemory())
        browser.selection = [7, 8, 9]
        #expect(browser.detailPane(sessionId: Self.sessionId) == .batch(count: 3))
    }

    @Test func aNewContactWinsUntilItEnds() throws {
        let browser = browser(try MailStore.inMemory())
        browser.beginNewContact(sessionId: Self.sessionId, scope: .all)
        guard case .newContact = browser.detailPane(sessionId: Self.sessionId) else {
            Issue.record("expected the new-contact editor")
            return
        }
        // Another login's column does not show this login's editor.
        #expect(browser.detailPane(sessionId: "other") == .nothing)
        browser.endNewContact(created: 12)
        #expect(browser.detailPane(sessionId: Self.sessionId) == .contact(12))
    }

    /// The model behind `.contact(id)` resolves that card from the mirror.
    @Test func theSelectedIdResolvesItsCard() async throws {
        let store = try MailStore.inMemory()
        let id = try await seedContact(store)
        let model = ContactDetailModel(contactId: id, store: store)
        let run = Task { await model.run() }
        defer { run.cancel() }
        try await waitUntil { model.hasLoaded }
        #expect(model.record?.id == id)
        #expect(model.record?.displayName == "Rory Gilmore")
        #expect(model.card != nil)
    }

    /// The regression, hosted for real because only SwiftUI decides whether a `.task` starts:
    /// the pane's loader hung off a `Group` that has no children until the card has loaded,
    /// and a `Group`'s modifiers go to its children — so the `.task` never started, and a
    /// clicked contact left the detail column blank. The list and the detail column sit in a
    /// split view as `RootSplitView` puts them; the row is selected through the list's table.
    @Test func selectingARowOpensTheCardInTheDetailColumn() async throws {
        let store = try MailStore.inMemory()
        let id = try await seedContact(store)
        let browser = browser(store)
        let sessionId = AccountSession.identifier(server: Self.identity.serverURL, loginName: Self.identity.loginName)
        let root = NavigationSplitView {
            Color.clear
        } content: {
            ContactsListView(sessionId: sessionId, scope: .all)
        } detail: {
            ContactsDetailColumn(sessionId: sessionId, scope: .all)
        }
        .environment(AppSession(store: store, initialTheme: .nextcloud))
        .environment(browser)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        try await waitUntil { Self.views(NSTableView.self, in: hosting).contains { $0.numberOfRows == 1 } }
        let table = try #require(Self.views(NSTableView.self, in: hosting).first { $0.numberOfRows == 1 })
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await waitUntil { browser.selection == [id] }
        #expect(browser.detailPane(sessionId: sessionId) == .contact(id))

        // The card is a `ScrollView`: a second scroll view besides the list's own.
        try await waitUntil {
            Self.views(NSScrollView.self, in: hosting).contains { $0 !== table.enclosingScrollView }
        }
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(type, in: $0) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func seedContact(_ store: MailStore) async throws -> Int64 {
        let loginId = try #require(try await store.ensureLogin(Self.identity).id)
        _ = try await store.upsert(accounts: [
            AccountWrite(
                identity: Self.identity, remoteId: 1, name: "Me", emailAddress: "me@example.invalid", rawJSON: "{}")
        ])
        let books = try await store.syncAddressBooks(
            [
                AddressBookRecord(
                    loginId: loginId,
                    url: "https://contacts.example.invalid/remote.php/dav/addressbooks/users/me/contacts/",
                    displayName: "Contacts")
            ],
            loginId: loginId)
        let client = DAVClient(
            server: try #require(URL(string: "https://contacts.example.invalid/")),
            credentials: BasicCredentials(loginName: "me", appPassword: "x"))
        let queue = MutationQueue(
            store: store,
            configuration: MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: client)))
        let actions = ContactsActions(loginId: loginId, store: store, queue: queue)
        var draft = ContactDraft.new(uid: "detail-rory")
        draft.given = "Rory"
        draft.family = "Gilmore"
        let book = try #require(books.first)
        return try #require(try await actions.create(draft, in: book))
    }
}
