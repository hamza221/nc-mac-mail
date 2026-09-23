// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import OSLog
import SwiftUI

/// The window everything else lives in.
///
/// Replaces WS-00's placeholder. `.ncTheme` is applied once here with whatever colour
/// `ThemeCache` cached on a previous launch, so the window never paints the stock Nextcloud
/// blue for a frame before recolouring itself — see `Theme/ThemeCache.swift` for why that
/// cache is `UserDefaults` rather than the `meta` table the brief first reached for.
///
/// `MailCommands` is the app's one keyboard-shortcut table, and `KeyboardShortcutsWindow` is
/// what Help ▸ Keyboard Shortcuts opens. Both take the same `TriageContext` the columns use,
/// because a menu item and a toolbar button that act on different state are two bugs waiting.
@main
struct NextcloudMailApp: App {
    @State private var session: AppSession

    init() {
        let store = NextcloudMailApp.openStore()
        _session = State(initialValue: AppSession(store: store, initialTheme: ThemeCache.cachedTheme()))
    }

    var body: some Scene {
        WindowGroup {
            RootSplitView(session: session)
                .environment(session)
                .ncTheme(session.theme)
                .task { await session.start() }
        }
        .commands {
            MailCommands(context: session.triage)
            SearchCommands(model: session.search)
        }
        KeyboardShortcutsWindow()
        Settings {
            SettingsScene()
                .environment(session)
        }
    }

    /// Falls back to an in-memory mirror rather than refusing to launch.
    /// `MailStoreError.unreadable` is meant to be recoverable through a "delete and
    /// re-mirror" flow, which belongs to WS-04's backfill or WS-12's storage panel, not the
    /// app's entry point — this is a stand-in until one of them adds it.
    private static func openStore() -> MailStore {
        do {
            return try MailStore(url: try MailStore.defaultDatabaseURL())
        } catch {
            Logger(subsystem: "com.nextcloud.mail.macos", category: "session")
                .fault("could not open the mirror; starting in-memory: \(String(describing: error), privacy: .public)")
            guard let inMemory = try? MailStore.inMemory() else {
                fatalError("could not open even an in-memory mirror")
            }
            return inMemory
        }
    }
}
