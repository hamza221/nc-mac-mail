// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
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
    /// Every login's and every account's sync engines (ADR-0084). The only thing in the app
    /// that starts one.
    let engine: AccountEngine
    /// WS-10's triage actions and their undo stack, built once here because every one of them
    /// writes to the same mirror and the menu bar needs the same instance the columns use.
    let triage: TriageContext
    /// WS-11's search. Here rather than in `RootSplitView` for the same reason as `triage`:
    /// `⌘F` is a `Commands` body outside the window, and it has to move the caret in the
    /// field the column is drawing.
    let search: SearchModel
    /// The mirror on disk could not be opened, so this session runs on an empty in-memory
    /// one that is lost at quit. `RootSplitView` offers the recovery: delete the file and
    /// download everything again.
    let mirrorIsTemporary: Bool
    /// `⌘P`. Here for the same reason as `triage`: the menu bar is outside the window, and
    /// the message pane registers what it is showing with this one instance.
    let printer = MessagePrintController()
    /// Whether the Keychain holds at least one account, from an attributes-only read.
    private var hasStoredAccounts: Bool
    private let networkMonitor = NetworkMonitor()
    private var themeObservation: Task<Void, Never>?
    /// `NSWorkspace.didWakeNotification`, held for the process's life like the rest of this
    /// object.
    private var wakeObserver: (any NSObjectProtocol)?
    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "session")

    init(store: MailStore, initialTheme: NCTheme, mirrorIsTemporary: Bool = false) {
        self.store = store
        self.mirrorIsTemporary = mirrorIsTemporary
        theme = initialTheme
        navigation = NavigationState(store: store)
        accounts = []
        hasStoredAccounts = AppSession.storedAccountCount() > 0
        engine = AccountEngine(store: store, status: status)
        triage = TriageContext(store: store)
        search = SearchModel(store: store)
    }

    /// Deletes the unreadable mirror and starts the app again, so the next launch opens a new
    /// one and mirrors every account from the server. Nothing is lost that the server does not
    /// have: queued actions lived in the same unreadable file.
    ///
    /// A relaunch rather than swapping the store in place: every column was built with this
    /// session's store at launch, and rebuilding them all is a second code path for a
    /// once-in-a-lifetime event.
    func deleteMirrorAndRelaunch() {
        do {
            try MailStore.deleteDatabase(at: try MailStore.defaultDatabaseURL())
        } catch {
            Self.logger.error("could not delete the unreadable mirror: \(String(describing: error), privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
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
        navigation.startMailbox = { [weak self] in
            await self?.engine.startMailbox()
        }
        navigation.startMailboxDidSettle = { [weak self] selection in
            await self?.engine.saveStartMailbox(selection)
        }
        connectTriage()
        networkMonitor.start { [weak self] conditions in
            guard let self else { return }
            status.isOffline = conditions.isOffline
            engine.apply(conditions: conditions)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.systemDidWake() }
        }
        observeTheme()
        accounts = await AppSession.accountsFromKeychain()
        // Now what was actually readable replaces the attributes-only guess from `init`: an
        // item whose consent prompt was denied leaves no account, and that user has to see
        // the sign-in screen rather than three empty columns with nothing behind them.
        hasStoredAccounts = !accounts.isEmpty
        engine.start(accounts: accounts)
        await navigation.load()
        await refreshTheme()
    }

    /// The hooks `TriageContext` leaves for whoever owns the sync engine: `R` refreshes the
    /// selected mailbox and its button spins while it runs, `⌘P` prints what the message
    /// pane registered, a committed action wakes that account's drainer, and the
    /// threaded-or-flat setting comes from the same `NavigationState` the columns read.
    ///
    /// `listStore` is set by `RootSplitView`, which is where the middle column's model is
    /// built. `⌘F` is `SearchCommands`'s, not a triage hook.
    private func connectTriage() {
        triage.navigation = navigation
        triage.refresh = { [weak self] in
            guard let self else { return }
            engine.refresh(mailboxId: navigation.selectedMailboxID)
        }
        triage.isRefreshing = { [weak self] in self?.status.isRefreshing ?? false }
        triage.printMessage = { [weak self] in self?.printer.printCurrentMessage() }
        triage.canPrintMessage = { [weak self] in self?.printer.canPrint ?? false }
        triage.actions.wakeDrainer = { [weak self] accountId in
            self?.engine.wakeDrainer(accountId: accountId)
        }
    }

    /// What the detail column needs to draw one message: the mirror it reads from, the client
    /// its WebView's scheme handler fetches assets with, the server those assets must come
    /// from, the coordinator that can move a missing body up the backfill queue, the
    /// queued "always show images from this sender", and WS-30's three engine doors — the
    /// login's server results, the account's queue and its exporter.
    ///
    /// - Parameter accountId: the account the selected mailbox belongs to. Nil, or an account
    ///   whose coordinator has not started yet, falls back to the first signed-in account so
    ///   the column is never empty while a row is still arriving.
    func messageServices(accountId: Int64?) -> MessageViewServices? {
        let trustSender: @MainActor (String, Int64) async -> Void = { [triage] email, accountId in
            await triage.actions.trustSender(email: email, accountId: accountId)
        }
        if let accountId, let running = engine.account(id: accountId) {
            return MessageViewServices(
                store: store,
                client: running.session.client,
                server: running.session.server,
                prioritiser: running.prioritiser,
                trustSender: trustSender,
                serverResults: engine.serverResults(sessionId: running.session.id),
                queue: engine.mutationQueue(accountId: accountId),
                exporter: engine.exporter(accountId: accountId),
                messageOpened: { [triage] messageId in await triage.actions.messageOpened(messageId) }
            )
        }
        guard let fallback = accounts.first else { return nil }
        return MessageViewServices(
            store: store,
            client: fallback.client,
            server: fallback.server,
            trustSender: trustSender
        )
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
        let session = AccountSession(server: credentials.server, credentials: credentials)
        accounts.removeAll { $0.id == session.id }
        accounts.append(session)
        if expiredAccount?.id == session.id {
            expiredAccount = nil
        }
        hasStoredAccounts = true
        engine.add(session)
        Task { await refreshTheme() }
    }

    /// Settings' sign-out, after it has removed the Keychain item (and, if asked, the
    /// account's rows). Signing out one account row signs out its whole login, because the
    /// Keychain item is the login's: every engine of it stops, its selection is dropped, and
    /// with `removeLocalCopies` the login row goes too — which is what takes its contacts,
    /// calendars and settings mirror with it — once nothing is left running to write them.
    func signedOut(account: AccountRecord, removeLocalCopies: Bool) async {
        let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
        accounts.removeAll { $0.id == sessionId }
        hasStoredAccounts = !accounts.isEmpty
        if expiredAccount?.id == sessionId {
            expiredAccount = nil
        }
        if case .contacts(let selected, _) = navigation.selection, selected == sessionId {
            navigation.select(nil)
        }
        await engine.signOut(sessionId: sessionId).value
        guard removeLocalCopies else { return }
        do {
            try await store.deleteLogin(ServerIdentity(serverURL: account.serverURL, loginName: account.loginName))
            try await store.vacuum()
        } catch {
            Self.logger.error("removing the login at sign-out failed: \(String(describing: error), privacy: .public)")
        }
        // The selected mailbox went with the login's rows: nothing to restore to.
        if let mailboxId = navigation.selectedMailboxID, (try? await store.mailbox(id: mailboxId)) == nil {
            navigation.select(nil)
        }
    }

    /// The Settings window opened: server state is re-read (`sync-engine.md`, the
    /// `.settingsOpened` trigger).
    func settingsOpened() {
        engine.settingsOpened()
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
                    return AccountSession(server: entry.server, credentials: credentials)
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
