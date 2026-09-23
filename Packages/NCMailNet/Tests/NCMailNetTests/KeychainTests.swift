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
///
/// **Off by default, and the reason is the developer's keychain, not the code.**
/// These write to the real login keychain. Every rebuild produces a binary with a
/// different identity, so macOS cannot match the item's ACL to the process asking
/// for it and puts up an "allow access" panel -- once per run, per item, forever.
/// A test suite that interrupts the person running it gets disabled by that
/// person, which is a worse outcome than gating it here. Same shape as
/// `SyncLiveMeasurementTests`, which is gated on a live server for the same
/// reason: the thing it needs is not present by default.
///
///     NCMAIL_KEYCHAIN_TESTS=1 swift test --filter Keychain
///
/// Run it when `Keychain.swift` changes. WS-00 separately proved `SecItem`
/// returns `errSecSuccess` under this project's sandbox entitlements, so what
/// these cover is this file's own logic, not whether the platform works.
/// File scope, not a static on the suite: `@Suite` cannot reference a member of
/// the type it is attached to -- the macro needs the value before the type is
/// resolved, and the compiler answers "circular reference resolving attached
/// macro".
private let keychainTestsEnabled = ProcessInfo.processInfo.environment["NCMAIL_KEYCHAIN_TESTS"] != nil

@Suite("Keychain", .serialized, .enabled(if: keychainTestsEnabled))
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
