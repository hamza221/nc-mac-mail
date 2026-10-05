// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import NCMailStore
import OSLog

/// Turns a ``SystemLink`` into what the user sees: a composer, or a row selected in the main
/// window. It only reads the mirror; nothing here reaches the network.
///
/// Selecting a message is the sidebar's mailbox, then the list's selection — the same two
/// writes a click makes. A new mailbox makes the list clear its selection when it starts
/// showing that mailbox (`MessageListStore.show`), so the row is selected only once the
/// list reports the mailbox as its source, or after ``settle`` if it never does (the window
/// is closed): the selection is then simply what the next window opens on.
@MainActor
final class SystemRouter {
    private let store: MailStore
    private let navigation: NavigationState
    private let openComposer: @MainActor (ComposeRequest) -> Void
    /// The message on its own, for when there is no main window to select it in.
    private let openMessageWindow: @MainActor (Int64) -> Void
    private let settle: Duration

    /// The main window's list and contacts models, attached by `.systemRouting`. Weak: the
    /// window owns them.
    weak var messageList: MessageListStore?
    weak var contacts: ContactsBrowser?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "system")

    init(
        store: MailStore,
        navigation: NavigationState,
        openComposer: @escaping @MainActor (ComposeRequest) -> Void,
        openMessageWindow: @escaping @MainActor (Int64) -> Void,
        settle: Duration = .seconds(2)
    ) {
        self.store = store
        self.navigation = navigation
        self.openComposer = openComposer
        self.openMessageWindow = openMessageWindow
        self.settle = settle
    }

    /// What a link resolved to, for the log and the tests.
    enum Outcome: Equatable {
        case composer(ComposeRequest)
        case message(Int64)
        case contact(Int64)
        case notFound
    }

    @discardableResult
    func handle(_ link: SystemLink) async -> Outcome {
        switch link {
        case .compose(let mailto):
            let request = ComposeRequest.new(accountId: nil, mailto: mailto)
            openComposer(request)
            return .composer(request)
        case .shared(let itemId):
            let request = ComposeRequest.shared(inboxItemId: itemId)
            openComposer(request)
            return .composer(request)
        case .openMessageId(let header):
            guard let message = try? await store.messages(messageIdHeader: header).first else {
                Self.logger.info("direct link names no mirrored message")
                return .notFound
            }
            await select(message)
            return .message(message.id)
        case .message(let id):
            guard let message = try? await store.message(id: id) else { return .notFound }
            await select(message)
            return .message(id)
        case .contact(let id):
            guard await selectContact(id) else { return .notFound }
            return .contact(id)
        }
    }

    private func select(_ message: MessageRecord) async {
        NSApp?.activate()
        guard let list = messageList else {
            openMessageWindow(message.id)
            return
        }
        navigation.select(.mailbox(message.mailboxId))
        await waitUntil { list.source?.mailboxId == message.mailboxId }
        list.selection = [message.id]
        // The list layout has no detail column: there the message opens in place.
        list.openedMessageId = message.id
    }

    /// The contact's address book in its login's Contacts section, then the row.
    private func selectContact(_ id: Int64) async -> Bool {
        guard let contact = try? await store.contact(id: id), !contact.isGroup,
            let logins = try? await store.logins()
        else { return false }
        for login in logins {
            guard let loginId = login.id,
                let books = try? await store.addressBooks(loginId: loginId),
                books.contains(where: { $0.id == contact.addressBookId })
            else { continue }
            NSApp?.activate()
            let sessionId = AccountSession.identifier(server: login.serverURL, loginName: login.loginName)
            let target = SidebarSelection.contacts(sessionId: sessionId, scope: .addressBook(contact.addressBookId))
            let changed = navigation.selection != target
            navigation.select(target)
            // The list clears its selection on a new scope, in `onChange` after the next
            // render; there is no model state to wait on, so this waits a render or two.
            if changed, contacts != nil { try? await Task.sleep(for: .milliseconds(200)) }
            contacts?.reveal(id)
            return true
        }
        return false
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: settle)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
