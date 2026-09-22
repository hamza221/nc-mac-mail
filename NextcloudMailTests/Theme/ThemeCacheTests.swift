// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NextcloudUI
import Testing

@testable import NextcloudMail

/// The launch colour and the refresh that replaces it.
///
/// Every `refresh` test replays `capabilities.json`, the response
/// `Scripts/record-fixtures.sh` recorded from a real server. The two tests that need a
/// *different* server answer edit those recorded bytes rather than inventing a payload, so a
/// shape the server never sends cannot creep in through a test.
@Suite("ThemeCache")
struct ThemeCacheTests {
    private static let server = "https://cloud.example.com"
    private static let brandedHex = "#aa0055"
    /// `ThemeCache.defaultsKey` is private and is spelled the same as `metaKey`. Repeating
    /// the literal keeps the two apart here, so a future split of the two keys shows up as a
    /// failing test rather than as tests that quietly follow the rename.
    private static let defaultsKey = "theme.primaryColorHex"

    // MARK: - The synchronous launch read

    @Test("a first launch gets the stock palette")
    func firstLaunchIsStock() async throws {
        try await withTemporaryDefaults { defaults in
            #expect(ThemeCache.cachedTheme(defaults: defaults) == .nextcloud)
        }
    }

    @Test("a cached colour that will not parse falls back to stock")
    func unparsableCachedColourFallsBack() async throws {
        try await withTemporaryDefaults { defaults in
            defaults.set("octarine", forKey: Self.defaultsKey)
            #expect(ThemeCache.cachedTheme(defaults: defaults) == .nextcloud)
        }
    }

    @Test("a cached colour is installed before the first frame")
    func cachedColourIsInstalled() async throws {
        try await withTemporaryDefaults { defaults in
            defaults.set(Self.brandedHex, forKey: Self.defaultsKey)
            let brand = try #require(NCBrand(primaryHex: Self.brandedHex))
            #expect(ThemeCache.cachedTheme(defaults: defaults) == NCTheme(brand: brand))
            #expect(ThemeCache.cachedTheme(defaults: defaults) != .nextcloud)
        }
    }

    // MARK: - The background refresh

    @Test("the recorded colour reaches both the mirror and the launch cache")
    func refreshStoresTheServersColour() async throws {
        let recorded = try FixtureBytes.decode(OCSResponse<Capabilities>.self, from: "capabilities.json")
        let colour = try #require(recorded.data.theming?.color)
        let store = try MailStore.inMemory()

        try await withTemporaryDefaults { defaults in
            let client = try Self.client(.replaying(try FixtureBytes.data("capabilities.json")))
            try await ThemeCache.refresh(client: client, store: store, defaults: defaults)

            #expect(defaults.string(forKey: Self.defaultsKey) == colour)
            #expect(try await store.metaValue(forKey: ThemeCache.metaKey) == colour)
        }
    }

    @Test("a 401 is the one failure that reaches the caller")
    func unauthorizedIsRethrown() async throws {
        let store = try MailStore.inMemory()

        try await withTemporaryDefaults { defaults in
            defaults.set(Self.brandedHex, forKey: Self.defaultsKey)
            let client = try Self.client(.answering(status: 401))

            do {
                try await ThemeCache.refresh(client: client, store: store, defaults: defaults)
                Issue.record("a 401 should have thrown")
            } catch MailError.unauthorized {
                // The modal sign-in prompt in ux-spec.md hangs off exactly this case.
            }

            #expect(defaults.string(forKey: Self.defaultsKey) == Self.brandedHex)
            #expect(try await store.metaValue(forKey: ThemeCache.metaKey) == nil)
        }
    }

    @Test("an offline refresh leaves the cached colour alone")
    func offlineKeepsTheCachedColour() async throws {
        let store = try MailStore.inMemory()

        try await withTemporaryDefaults { defaults in
            defaults.set(Self.brandedHex, forKey: Self.defaultsKey)
            let client = try Self.client(.offline)

            try await ThemeCache.refresh(client: client, store: store, defaults: defaults)

            #expect(defaults.string(forKey: Self.defaultsKey) == Self.brandedHex)
            #expect(try await store.metaValue(forKey: ThemeCache.metaKey) == nil)
        }
    }

    @Test("an instance that reports no theming writes nothing")
    func missingThemingWritesNothing() async throws {
        let store = try MailStore.inMemory()
        let body = try Self.recordedCapabilities { $0.removeValue(forKey: "theming") }

        try await withTemporaryDefaults { defaults in
            let client = try Self.client(.replaying(body))
            try await ThemeCache.refresh(client: client, store: store, defaults: defaults)

            #expect(defaults.string(forKey: Self.defaultsKey) == nil)
            #expect(try await store.metaValue(forKey: ThemeCache.metaKey) == nil)
        }
    }

    @Test("a colour that will not parse is not cached")
    func unparsableServerColourWritesNothing() async throws {
        let store = try MailStore.inMemory()
        let body = try Self.recordedCapabilities { capabilities in
            var theming = capabilities["theming"] as? [String: Any] ?? [:]
            theming["color"] = "octarine"
            capabilities["theming"] = theming
        }

        try await withTemporaryDefaults { defaults in
            let client = try Self.client(.replaying(body))
            try await ThemeCache.refresh(client: client, store: store, defaults: defaults)

            #expect(defaults.string(forKey: Self.defaultsKey) == nil)
            #expect(try await store.metaValue(forKey: ThemeCache.metaKey) == nil)
        }
    }

    // MARK: - Helpers

    /// `RetryPolicy.none`, so nothing in this suite can sleep: the transport failure test
    /// would otherwise back off for 2, 8 and 30 seconds before giving up.
    private static func client(_ transport: ReplayTransport) throws -> MailClient {
        MailClient(
            server: try #require(URL(string: server)),
            credentials: BasicCredentials(loginName: "alice", appPassword: "app-password"),
            transport: transport,
            retryPolicy: .none
        )
    }

    /// The recorded capabilities response with its `capabilities` object edited.
    ///
    /// Removing a field the server did send is a truthful way to test the absent case;
    /// writing a fresh JSON literal would only test this file's idea of the payload.
    private static func recordedCapabilities(editing edit: (inout [String: Any]) -> Void) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: try FixtureBytes.data("capabilities.json"))
        var root = try #require(object as? [String: Any])
        var ocs = try #require(root["ocs"] as? [String: Any])
        var payload = try #require(ocs["data"] as? [String: Any])
        var capabilities = try #require(payload["capabilities"] as? [String: Any])

        edit(&capabilities)

        payload["capabilities"] = capabilities
        ocs["data"] = payload
        root["ocs"] = ocs
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A `UserDefaults` suite of its own per test, removed afterwards, so nothing leaks into
    /// the host app's real preferences or into the next test.
    private func withTemporaryDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "ThemeCacheTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

}
