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

/// The §7 tabs (ux-spec "App settings (WS-38)"), `Form` plus `.formStyle(.grouped)`
/// throughout. The library's own guidance is that a settings pane needs nothing wrapping
/// that ([SettingsSections.md](../../../docs/reference/ui-components.md)).
private struct SettingsRootView: View {
    let session: AppSession
    @State private var settingsStore: SettingsStore
    @State private var appSettings: AppSettingsModel
    @AppStorage(SettingsTab.preferredTabKey) private var selectedTab = SettingsTab.general

    init(session: AppSession) {
        self.session = session
        let settingsStore = SettingsStore(store: session.store, sessions: session.accounts)
        settingsStore.signedOut = { [weak session] account, removeLocalCopies in
            await session?.signedOut(account: account, removeLocalCopies: removeLocalCopies)
        }
        _settingsStore = State(initialValue: settingsStore)
        let engine = session.engine
        let listPreferences = MessageListPreferenceStore(store: session.store) { engine.mutationQueue(accountId: $0) }
        _appSettings = State(
            initialValue: AppSettingsModel(
                store: session.store, listPreferences: listPreferences, services: .live(session)))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                content(for: tab)
                    .tabItem { Text(tab.title) }
                    .tag(tab)
            }
        }
        .environment(settingsStore)
        .environment(appSettings)
        .ncTheme(session.theme)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 360, idealHeight: 480)
        .task {
            settingsStore.start()
            appSettings.start()
            session.settingsOpened()
        }
        .onDisappear {
            settingsStore.stop()
            appSettings.stop()
        }
        .onChange(of: session.accounts) { _, newValue in
            settingsStore.updateSessions(newValue)
        }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .accounts: AccountsSettingsView()
        case .appearance: AppearanceSettingsView()
        case .messages: MessagesSettingsView()
        case .privacy: PrivacySettingsView()
        case .security: SecuritySettingsView()
        case .assistance: AssistanceSettingsView()
        case .contextChat: ContextChatSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .storage: StorageSettingsView()
        case .about: AboutSettingsView()
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
enum SettingsTab: String, CaseIterable {
    case general
    case accounts
    case appearance
    case messages
    case privacy
    case security
    case assistance
    case contextChat
    case shortcuts
    case storage
    case about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .accounts: String(localized: "Accounts")
        case .appearance: String(localized: "Appearance")
        case .messages: String(localized: "Messages")
        case .privacy: String(localized: "Privacy")
        case .security: String(localized: "Security")
        case .assistance: String(localized: "Assistance")
        case .contextChat: String(localized: "Context Chat")
        case .shortcuts: String(localized: "Shortcuts")
        case .storage: String(localized: "Storage")
        case .about: String(localized: "About")
        }
    }

    static let preferredTabKey = "settings.preferredTab"

    static var preferredTab: SettingsTab {
        get { SettingsTab(rawValue: UserDefaults.standard.string(forKey: preferredTabKey) ?? "") ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferredTabKey) }
    }

    static let preferredAccountIDKey = "settings.preferredAccountId"

    /// The account the Accounts tab shows, written by anything that deep-links to one
    /// account's settings (the sidebar's "Account settings…", General's account rows) before
    /// it selects ``accounts``. Nil when nothing asked for one.
    static var preferredAccountID: Int64? {
        get { (UserDefaults.standard.object(forKey: preferredAccountIDKey) as? NSNumber)?.int64Value }
        set {
            if let newValue {
                UserDefaults.standard.set(NSNumber(value: newValue), forKey: preferredAccountIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredAccountIDKey)
            }
        }
    }
}
