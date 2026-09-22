// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailNet

/// Exercises the real `SecItem*` calls against the local keychain, against a
/// server and login name no real account would ever use. Not a network test —
/// [definition-of-done.md](../../../../docs/delivery/definition-of-done.md) bars the
/// network, not the keychain — and WS-00 already proved `SecItem` returns
/// `errSecSuccess` under this project's sandbox entitlements, so a fake here
/// would test the fake rather than the thing the brief asks to confirm.
///
/// `.serialized` because every test in this file shares one keychain item.
@Suite("Keychain", .serialized)
struct KeychainTests {
    static let server = URL(string: "https://ncmailnet-tests.invalid/nextcloud")!
    static let loginName = "ws01-test-account"

    init() {
        // Best-effort cleanup in case a previous run crashed mid-test and
        // left the item behind.
        try? Keychain.delete(server: Self.server, loginName: Self.loginName)
    }

    @Test("save then load round-trips the credentials exactly")
    func saveAndLoad() throws {
        let credentials = Credentials(
            server: Self.server, loginName: Self.loginName, appPassword: "a-test-app-password")
        try Keychain.save(credentials)
        defer { try? Keychain.delete(server: Self.server, loginName: Self.loginName) }

        let loaded = try Keychain.load(server: Self.server, loginName: Self.loginName)
        #expect(loaded == credentials)
    }

    @Test("save overwrites an existing item rather than duplicating it")
    func saveOverwrites() throws {
        try Keychain.save(
            Credentials(server: Self.server, loginName: Self.loginName, appPassword: "first-password"))
        try Keychain.save(
            Credentials(server: Self.server, loginName: Self.loginName, appPassword: "second-password"))
        defer { try? Keychain.delete(server: Self.server, loginName: Self.loginName) }

        let loaded = try Keychain.load(server: Self.server, loginName: Self.loginName)
        #expect(loaded?.appPassword == "second-password")
    }

    @Test("load returns nil for an account that was never saved")
    func loadMissing() throws {
        let loaded = try Keychain.load(server: Self.server, loginName: "no-such-account")
        #expect(loaded == nil)
    }

    @Test("delete on an item that is not there does not throw")
    func deleteMissingDoesNotThrow() throws {
        try Keychain.delete(server: Self.server, loginName: "no-such-account")
    }

    @Test("delete removes the item; the next load sees nothing, as sign-out requires")
    func deleteRemoves() throws {
        try Keychain.save(
            Credentials(server: Self.server, loginName: Self.loginName, appPassword: "a-test-app-password"))
        try Keychain.delete(server: Self.server, loginName: Self.loginName)

        let loaded = try Keychain.load(server: Self.server, loginName: Self.loginName)
        #expect(loaded == nil)
    }

    @Test("allAccounts lists a saved account by server and login name")
    func allAccountsListsTheSavedAccount() throws {
        try Keychain.save(
            Credentials(server: Self.server, loginName: Self.loginName, appPassword: "a-test-app-password"))
        defer { try? Keychain.delete(server: Self.server, loginName: Self.loginName) }

        let accounts = try Keychain.allAccounts()
        #expect(accounts.contains { $0.server == Self.server && $0.loginName == Self.loginName })
    }
}
