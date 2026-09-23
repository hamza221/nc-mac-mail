// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NextcloudUI
import OSLog
import SwiftUI

/// Everything the app needs before it can show anything: every signed-in account, the running
/// theme, and the one status object every column reads from.
///
/// `NextcloudMailApp` builds exactly one of these at launch and hands it down through the
/// environment. Which accounts exist is read in `init`, from Keychain *attributes*, so a
/// returning user's first frame already shows the three columns with no async gap in which
/// `needsSignIn` would answer wrongly. The passwords are read afterwards, off the main
/// thread: `SecItemCopyMatching` blocks on a consent dialog when the item's ACL does not
/// match the running binary, and an ad-hoc signature changes on every build
/// ([ADR-0054](../../docs/decisions/0054-the-passwords-are-read-off-the-main-thread.md)).
@MainActor
@Observable
final class AppSession {
    private(set) var accounts: [AccountSession]
    private(set) var theme: NCTheme
    let status = AppStatus()
    let navigation: NavigationState

    /// Set when an account's session expires (401). Non-nil means the one modal
    /// [ux-spec.md](../../docs/product/ux-spec.md#errors-and-the-rule-about-them) allows is on
    /// screen.
    var expiredAccount: AccountSession?

    /// True until at least one account exists. `RootSplitView` shows `LoginView` instead of
    /// the three columns for as long as this holds.
    ///
    /// It answers from the Keychain's attributes before any password has been read, so the
    /// window does not open on the sign-in screen and then replace it a moment later.
    var needsSignIn: Bool { accounts.isEmpty && !hasStoredAccounts }

    /// Internal, not private: the three columns each build their own store-backed model
    /// (`SidebarStore`, `MessageListStore`, `MessageViewServices`) and all three take a
    /// `MailStore`. One mirror is opened per process, in `NextcloudMailApp.init()`, and this
    /// is how everything else gets it.
    let store: MailStore
    /// Every account's coordinator, drainer and scheduler. The only thing in the app that
    /// starts one.
    let engine: AccountEngine
    /// WS-10's triage actions and their undo stack, built once here because every one of them
    /// writes to the same mirror and the menu bar needs the same instance the columns use.
    let triage: TriageContext
    /// WS-11's search. Here rather than in `RootSplitView` for the same reason as `triage`:
    /// `⌘F` is a `Commands` body outside the window, and it has to move the caret in the
    /// field the column is drawing.
    let search: SearchModel
    /// Whether the Keychain holds at least one account, from an attributes-only read.
    private var hasStoredAccounts: Bool
    private let networkMonitor = NetworkMonitor()
    private var themeObservation: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "session")

    init(store: MailStore, initialTheme: NCTheme) {
        self.store = store
        theme = initialTheme
        navigation = NavigationState(store: store)
        accounts = []
        hasStoredAccounts = AppSession.storedAccountCount() > 0
        engine = AccountEngine(store: store, status: status)
        triage = TriageContext(store: store)
        search = SearchModel(store: store)
    }

    // No `deinit` cancelling `themeObservation`: exactly one `AppSession` exists, built once
    // in `NextcloudMailApp.init()` and held for the process's whole life, so it is never
    // deallocated while the app runs. `observeTheme()` still captures `self` weakly, which is
    // what would matter if that ever changed.

    /// Everything that can wait until after the first frame: starting the path monitor,
    /// watching `meta` for a theme change, loading the last-known selection, and asking the
    /// network for a fresh brand colour.
    func start() async {
        engine.sessionExpired = { [weak self] account in
            self?.expiredAccount = account
        }
        navigation.mailboxDidChange = { [weak self] mailboxId in
            self?.engine.setSelectedMailbox(mailboxId)
        }
        connectTriage()
        networkMonitor.start { [weak self] conditions in
            guard let self else { return }
            status.isOffline = conditions.isOffline
            engine.apply(conditions: conditions)
        }
        observeTheme()
        accounts = await AppSession.accountsFromKeychain()
        hasStoredAccounts = hasStoredAccounts || !accounts.isEmpty
        engine.start(accounts: accounts)
        await navigation.load()
        await refreshTheme()
    }

    /// The three hooks `TriageContext` leaves for whoever owns the sync engine: `R` refreshes
    /// the selected mailbox, a committed action wakes that account's drainer, and the
    /// threaded-or-flat setting comes from the same `NavigationState` the columns read.
    ///
    /// `listStore` is set by `RootSplitView`, which is where the middle column's model is
    /// built. Printing and search stay nil until WS-09 and WS-11 offer something to call.
    private func connectTriage() {
        triage.navigation = navigation
        triage.refresh = { [weak self] in
            guard let self else { return }
            engine.refresh(mailboxId: navigation.selectedMailboxID)
        }
        triage.actions.wakeDrainer = { [weak self] accountId in
            self?.engine.wakeDrainer(accountId: accountId)
        }
    }

    /// What the detail column needs to draw one message: the mirror it reads from, the client
    /// its WebView's scheme handler fetches assets with, the server those assets must come
    /// from, and the coordinator that can move a missing body up the backfill queue.
    ///
    /// - Parameter accountId: the account the selected mailbox belongs to. Nil, or an account
    ///   whose coordinator has not started yet, falls back to the first signed-in account so
    ///   the column is never empty while a row is still arriving.
    func messageServices(accountId: Int64?) -> MessageViewServices? {
        if let accountId, let running = engine.account(id: accountId) {
            return MessageViewServices(
                store: store,
                client: running.session.client,
                server: running.session.server,
                prioritiser: running.prioritiser
            )
        }
        guard let fallback = accounts.first else { return nil }
        return MessageViewServices(store: store, client: fallback.client, server: fallback.server)
    }

    /// `theme` only ever changes here, in response to `meta` changing — never as a direct
    /// answer to the network call in `refreshTheme()`. That is what keeps the brand colour
    /// inside "the network only writes to the database"
    /// ([overview.md](../../docs/architecture/overview.md#the-invariant)) rather than being
    /// the one place a network response feeds a render directly.
    private func observeTheme() {
        themeObservation?.cancel()
        themeObservation = Task { [weak self] in
            // Capturing `store` rather than `self` for the sequence itself means the task
            // does not keep `AppSession` alive for as long as it runs; `self` is re-checked,
            // weakly, on every value.
            guard let store = self?.store else { return }
            do {
                for try await hex in store.observeMetaValue(forKey: ThemeCache.metaKey) {
                    guard let self, let hex, let brand = NCBrand(primaryHex: hex) else { continue }
                    self.theme = NCTheme(brand: brand)
                }
            } catch {
                Self.logger.error("theme observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `LoginView`'s `onSignedIn`, for both the very first account and for answering the 401
    /// modal. Either way the result is the same: this account, freshly authenticated,
    /// replaces whatever was there before under the same identity.
    func signedIn(_ credentials: Credentials) {
        let session = AccountSession(
            server: credentials.server,
            loginName: credentials.loginName,
            client: MailClient(server: credentials.server, credentials: credentials)
        )
        accounts.removeAll { $0.id == session.id }
        accounts.append(session)
        if expiredAccount?.id == session.id {
            expiredAccount = nil
        }
        hasStoredAccounts = true
        engine.add(session)
        Task { await refreshTheme() }
    }

    /// How many accounts the Keychain holds, without reading a single password.
    ///
    /// Attributes do not decrypt the item, so this call cannot block on a consent dialog the
    /// way ``accountsFromKeychain()`` can, which is what makes it safe to run in `init`.
    private static func storedAccountCount() -> Int {
        do {
            return try Keychain.allAccounts().count
        } catch {
            logger.error("could not count Keychain accounts: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    /// Reads every account the Keychain knows about and builds a client for each. One entry
    /// that cannot be read — corrupted, or removed between the enumeration and the read —
    /// is skipped rather than failing the rest, which is what keeps a second account working
    /// when the first one's app password was revoked.
    ///
    /// Off the main thread, on a detached task, because reading the password decrypts the
    /// item: when the item's access control does not name the running binary, `SecItem`
    /// blocks inside `securityd` until somebody answers a dialog. On the main thread that is
    /// a frozen launch with no window behind the prompt (ADR-0054).
    private static func accountsFromKeychain() async -> [AccountSession] {
        await Task.detached(priority: .userInitiated) { readKeychainAccounts() }.value
    }

    private nonisolated static func readKeychainAccounts() -> [AccountSession] {
        let entries: [(server: URL, loginName: String)]
        do {
            entries = try Keychain.allAccounts()
        } catch {
            logger.error("could not enumerate Keychain accounts: \(String(describing: error), privacy: .public)")
            return []
        }

        return
            entries
            .sorted { ($0.server.absoluteString, $0.loginName) < ($1.server.absoluteString, $1.loginName) }
            .compactMap { entry in
                do {
                    guard let credentials = try Keychain.load(server: entry.server, loginName: entry.loginName)
                    else {
                        return nil
                    }
                    let client = MailClient(server: entry.server, credentials: credentials)
                    return AccountSession(server: entry.server, loginName: entry.loginName, client: client)
                } catch {
                    logger.error("one Keychain account could not be read; continuing with the rest")
                    return nil
                }
            }
    }

    /// Brand comes from a server, and the app has one theme, not one per account. The first
    /// account, in a stable (sorted) order, decides it for everyone until there is a more
    /// deliberate answer — see this workstream's report for why that is a finding rather than
    /// a settled design.
    private func refreshTheme() async {
        guard let primary = accounts.first else { return }
        do {
            try await ThemeCache.refresh(client: primary.client, store: store)
        } catch {
            expiredAccount = primary
        }
    }
}
