// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// What the fetcher writes, and the promise that it asks about each correspondent once.
@Suite("Avatar fetcher")
struct AvatarFetcherTests {
    /// The first bytes of a real PNG. Never decoded here; the app's loader decodes.
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    /// Three messages from `sender1…3@example.invalid`, newest from sender3.
    private static func fixture() async throws -> (MailStore, FakeTransport, AvatarFetcher) {
        let store = try MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: 3)
        let transport = FakeTransport()
        let fetcher = AvatarFetcher(store: store, client: try MirrorTest.client(transport), accountId: seed.accountId)
        return (store, transport, fetcher)
    }

    @Test("a photo is stored with its type, a 404 is remembered, and a second pass asks nothing")
    func storesPhotosAndMisses() async throws {
        let (store, transport, fetcher) = try await Self.fixture()
        await transport.stub(
            .pathContains("avatars/image/sender3"),
            with: StubResponse(status: 200, body: Self.png, headers: ["Content-Type": "image/png"])
        )
        await transport.stub(.pathContains("avatars/image/"), with: .status(404))

        #expect(await fetcher.runPass() == 3)

        let photo = try #require(try await store.avatar(for: "sender3@example.invalid"))
        #expect(photo.data == Self.png)
        #expect(photo.mime == "image/png")
        #expect(!photo.missing)
        #expect(try await store.avatar(for: "SENDER1@example.invalid")?.missing == true)

        let asked = await transport.sendCount
        #expect(await fetcher.runPass() == 0)
        #expect(await transport.sendCount == asked)
    }

    @Test("a transport failure ends the pass and leaves the address to be asked again")
    func failureLeavesNoRow() async throws {
        let (store, transport, fetcher) = try await Self.fixture()
        await transport.fail(.pathContains("avatars/image/"), times: 1_000, then: .status(404))

        #expect(await fetcher.runPass() == 0)
        #expect(try await store.avatar(for: "sender3@example.invalid") == nil)
    }

    @Test("in Low Data Mode the fetcher asks for nothing")
    func lowDataModeAsksNothing() async throws {
        let (_, transport, fetcher) = try await Self.fixture()
        await transport.stub(.pathContains("avatars/image/"), with: .status(404))
        await fetcher.apply(conditions: MirrorConditions(isConstrained: true))

        #expect(await fetcher.runPass() == 0)
        #expect(await transport.sendCount == 0)
    }
}
