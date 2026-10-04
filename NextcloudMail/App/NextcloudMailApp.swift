// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
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
    @NSApplicationDelegateAdaptor(SystemAppDelegate.self) private var systemDelegate  // WS-42 exception

    init() {
        let (store, isTemporary) = NextcloudMailApp.openStore()
        _session = State(
            initialValue: AppSession(
                store: store, initialTheme: ThemeCache.cachedTheme(), mirrorIsTemporary: isTemporary)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootSplitView(session: session)
                .environment(session)
                .ncTheme(session.theme)
                .task {
                    // The host of a test run keeps its session inert — see `isHostingTests`.
                    guard !Self.isHostingTests else { return }
                    await session.start()
                }
                .systemIntegration(session: session)  // WS-42 exception
                .mailNotifications(session.notifier)  // WS-41 exception
        }
        .commands {
            MailCommands(context: session.triage)
            SearchCommands(model: session.search)
        }
        KeyboardShortcutsWindow()
        ComposerScene(session: session)
        MessageWindowScene(session: session)
        Settings {
            SettingsScene()
                .environment(session)
        }
    }

    /// True when this process hosts a test run rather than a user's app.
    ///
    /// The suites build their own stores and sessions, so the launch that hosts them stays
    /// inert: it never opens the developer's real mirror, never starts engines against it,
    /// and never reads a real Keychain item. The last one is the sharp edge:
    /// `SecItemCopyMatching` answers with a consent dialog whenever the item's ACL does not
    /// match the running binary, and an ad-hoc signature changes on every build (ADR-0054),
    /// so a hosted launch that read passwords would prompt again on every rebuild (ADR-0103).
    ///
    /// The environment variables are the half that is already set when `init` runs; the
    /// class check covers anything that asks after the runner has injected the test bundle.
    static var isHostingTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    /// Falls back to an in-memory mirror rather than refusing to launch, and says so:
    /// `RootSplitView` then offers to delete the unreadable file and download everything
    /// again (`AppSession.mirrorIsTemporary`), which is the recovery
    /// `MailStoreError.unreadable` exists to make possible. A hosted test run opens an
    /// in-memory mirror instead — deliberate, so not `isTemporary` — and never the real one.
    static func openStore() -> (MailStore, isTemporary: Bool) {
        if isHostingTests {
            guard let inert = try? MailStore.inMemory() else {
                fatalError("could not open even an in-memory mirror")
            }
            return (inert, false)
        }
        do {
            return (try MailStore(url: try MailStore.defaultDatabaseURL()), false)
        } catch {
            Logger(subsystem: "com.nextcloud.mail.macos", category: "session")
                .fault("could not open the mirror; starting in-memory: \(String(describing: error), privacy: .public)")
            guard let inMemory = try? MailStore.inMemory() else {
                fatalError("could not open even an in-memory mirror")
            }
            return (inMemory, true)
        }
    }
}
