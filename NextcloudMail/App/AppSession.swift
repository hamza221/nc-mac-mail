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
/// environment. Accounts come from the Keychain, which is a synchronous API
/// ([Keychain.swift](../../Packages/NCMailNet/Sources/NCMailNet/Auth/Keychain.swift)), so
/// `accounts` is populated in `init` itself — a returning user's first frame already shows
/// the three columns, with no async gap in which `needsSignIn` would answer wrongly.
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
    var needsSignIn: Bool { accounts.isEmpty }

    private let store: MailStore
    private let networkMonitor = NetworkMonitor()
    private var themeObservation: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "session")

    init(store: MailStore, initialTheme: NCTheme) {
        self.store = store
        theme = initialTheme
        navigation = NavigationState(store: store)
        accounts = AppSession.accountsFromKeychain()
    }

    // No `deinit` cancelling `themeObservation`: exactly one `AppSession` exists, built once
    // in `NextcloudMailApp.init()` and held for the process's whole life, so it is never
    // deallocated while the app runs. `observeTheme()` still captures `self` weakly, which is
    // what would matter if that ever changed.

    /// Everything that can wait until after the first frame: starting the path monitor,
    /// watching `meta` for a theme change, loading the last-known selection, and asking the
    /// network for a fresh brand colour.
    func start() async {
        networkMonitor.start { [weak self] isOffline in
            self?.status.isOffline = isOffline
        }
        observeTheme()
        await navigation.load()
        await refreshTheme()
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
        Task { await refreshTheme() }
    }

    /// Reads every account the Keychain knows about and builds a client for each. One entry
    /// that cannot be read — corrupted, or removed between the enumeration and the read —
    /// is skipped rather than failing the rest, which is what keeps a second account working
    /// when the first one's app password was revoked.
    private static func accountsFromKeychain() -> [AccountSession] {
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
