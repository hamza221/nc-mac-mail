// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The `Settings` scene `NextcloudMailApp` installs, with the session in the environment.
///
/// `SettingsScene` itself only reads `AppSession` out of the environment; the `@State` that
/// needs `session.store` and `session.accounts` lives one level down, in
/// ``SettingsRootView``, because a view's `init` runs before its `@Environment` properties
/// are populated.
///
/// `SidebarStore.showStorage(_:)` and `.signOut(_:)` write ``SettingsTab/preferredTab``,
/// and the sidebar then opens the window with `openSettings`. The tab is bound to that same
/// key, so a click on "Storage…" or "Sign out" lands on the right tab, even when the window
/// is already open on another one (ADR-0062).
struct SettingsScene: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        SettingsRootView(session: session)
    }
}

/// Three tabs, `Form` plus `.formStyle(.grouped)` throughout. The library's own guidance is
/// that a settings pane needs nothing wrapping that
/// ([SettingsSections.md](../../../docs/reference/ui-components.md)).
private struct SettingsRootView: View {
    let session: AppSession
    @State private var settingsStore: SettingsStore
    @AppStorage(SettingsTab.preferredTabKey) private var selectedTab = SettingsTab.general

    init(session: AppSession) {
        self.session = session
        let settingsStore = SettingsStore(store: session.store, sessions: session.accounts)
        settingsStore.signedOut = { [weak session] account, removeLocalCopies in
            await session?.signedOut(account: account, removeLocalCopies: removeLocalCopies)
        }
        _settingsStore = State(initialValue: settingsStore)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Text("General") }
                .tag(SettingsTab.general)
            AccountsSettingsView()
                .tabItem { Text("Accounts") }
                .tag(SettingsTab.accounts)
            StorageSettingsView()
                .tabItem { Text("Storage") }
                .tag(SettingsTab.storage)
        }
        .environment(settingsStore)
        .ncTheme(session.theme)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 420)
        .task {
            settingsStore.start()
            session.settingsOpened()
        }
        .onDisappear { settingsStore.stop() }
        .onChange(of: session.accounts) { _, newValue in
            settingsStore.updateSessions(newValue)
        }
    }
}

/// Which tab the Settings window shows.
///
/// One `UserDefaults` key, bound with `@AppStorage` in ``SettingsRootView`` and written by
/// the sidebar's "Storage…" and "Sign out" actions, so the window follows a request even
/// when it is already open, and reopens on the tab last used
/// ([ThemeCache](../Theme/ThemeCache.swift) is the precedent for a small, non-sensitive
/// value living in `UserDefaults` rather than the database).
enum SettingsTab: String {
    case general
    case accounts
    case storage

    static let preferredTabKey = "settings.preferredTab"

    static var preferredTab: SettingsTab {
        get { SettingsTab(rawValue: UserDefaults.standard.string(forKey: preferredTabKey) ?? "") ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferredTabKey) }
    }
}
