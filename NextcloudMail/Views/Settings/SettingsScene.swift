// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The real `Settings` scene, replacing `NextcloudMailApp.swift`'s `SettingsPlaceholder`.
///
/// `NextcloudMailApp.swift` is WS-13's file and another agent is editing it while this one
/// runs, so this workstream stops at building the scene and leaves the one-line swap to the
/// report rather than touching that file:
///
/// ```swift
/// Settings {
///     SettingsScene()
///         .environment(session)
/// }
/// ```
///
/// `SettingsScene` itself only reads `AppSession` out of the environment; the `@State` that
/// needs `session.store` and `session.accounts` lives one level down, in
/// ``SettingsRootView``, because a view's `init` runs before its `@Environment` properties
/// are populated.
///
/// `SidebarStore.showStorage(_:)` and `.signOut(_:)` (WS-07's file; this workstream owns
/// only those two method bodies, per its brief) write ``SettingsTab/preferredTab`` before
/// asking AppKit to show the Settings window, so a click on "Storage…" or "Sign Out…" in the
/// sidebar opens on the right tab rather than whichever one was last visible.
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
    @State private var selectedTab = SettingsTab.preferredTab

    init(session: AppSession) {
        self.session = session
        _settingsStore = State(initialValue: SettingsStore(store: session.store, sessions: session.accounts))
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
        .task { settingsStore.start() }
        .onDisappear { settingsStore.stop() }
        .onChange(of: session.accounts) { _, newValue in
            settingsStore.updateSessions(newValue)
        }
    }
}

/// Which tab the Settings window opens on.
///
/// Read once, at this view's `init`, from the same `UserDefaults` key the sidebar's
/// "Storage…" and "Sign Out…" actions write before asking AppKit to show the window
/// ([ThemeCache](../Theme/ThemeCache.swift) is the precedent for a small, non-sensitive
/// value living in `UserDefaults` rather than the database). Switching tabs afterward is
/// ordinary `TabView` selection and never touches this key again.
enum SettingsTab: String {
    case general
    case accounts
    case storage

    /// The key `SidebarStore.openSettings(on:)` writes before asking AppKit to show the
    /// window. `SidebarStore` names this type directly, since it is the same app target and
    /// needs no import, and this constant is what keeps the string in one place rather than
    /// two.
    static let preferredTabKey = "settings.preferredTab"

    static var preferredTab: SettingsTab {
        SettingsTab(rawValue: UserDefaults.standard.string(forKey: preferredTabKey) ?? "") ?? .general
    }
}
