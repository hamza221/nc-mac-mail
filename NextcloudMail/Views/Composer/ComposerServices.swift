// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore

/// What a composer needs from the app: the mirror, the engines, which mailbox is on screen
/// and how the message view is served (for the read-only quote).
///
/// A value rather than `AppSession` itself so a composer can run against a bare
/// `AccountEngine` — the live acceptance test does, because building an `AppSession` reads
/// the Keychain, which blocks behind the test host's own consent prompt.
@MainActor
struct ComposerServices {
    let store: MailStore
    let engine: AccountEngine
    var selectedMailboxId: @MainActor () -> Int64?
    var messageServices: @MainActor (Int64?) -> MessageViewServices?

    init(
        store: MailStore,
        engine: AccountEngine,
        selectedMailboxId: @escaping @MainActor () -> Int64? = { nil },
        messageServices: @escaping @MainActor (Int64?) -> MessageViewServices? = { _ in nil }
    ) {
        self.store = store
        self.engine = engine
        self.selectedMailboxId = selectedMailboxId
        self.messageServices = messageServices
    }

    init(session: AppSession) {
        self.init(
            store: session.store,
            engine: session.engine,
            selectedMailboxId: { [weak session] in session?.navigation.selectedMailboxID },
            messageServices: { [weak session] accountId in session?.messageServices(accountId: accountId) }
        )
    }
}
