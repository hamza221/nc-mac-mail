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

    // MARK: - Addresses SQLite and Swift fold differently

    /// SQLite's `lower()` folds ASCII only; Swift's `lowercased()` folds all of Unicode. A
    /// sender whose address has a character the two disagree on is where the work list and
    /// the stored key used to part ways, and the pass asked about it forever.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// An account whose mail comes from `senders`, newest last, and a fetcher whose clock is
    /// ``now``.
    private static func fixture(senders: [String]) async throws -> (MailStore, FakeTransport, AvatarFetcher) {
        let store = try MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: 0)
        try await store.upsert(
            envelopes: senders.enumerated().map { offset, email in
                EnvelopeWrite(
                    remoteId: Int64(offset) + 1,
                    mailboxId: seed.mailboxId,
                    accountId: seed.accountId,
                    sentAt: 1_700_000_000 + Int64(offset),
                    syncedAt: 1_700_000_000 + Int64(offset),
                    fromEmail: email,
                    addresses: [EnvelopeAddress(kind: .from, email: email)]
                )
            }
        )
        let transport = FakeTransport()
        let fetcher = AvatarFetcher(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: seed.accountId,
            now: { Self.now }
        )
        return (store, transport, fetcher)
    }

    /// The last path segment of every avatar request, decoded: which address was asked about.
    private static func askedAddresses(_ transport: FakeTransport) async -> [String] {
        await transport.requestPaths.compactMap { $0.split(separator: "/").last.map(String.init) }
    }

    @Test(
        "an address with a non-ASCII capital is asked about once a pass, and a look-alike never replaces another sender's photo"
    )
    func nonASCIIFoldTerminates() async throws {
        let kelvin = "\u{212A}evin@example.invalid"
        let (store, transport, fetcher) = try await Self.fixture(
            senders: ["kevin@example.invalid", "Ö@example.invalid", kelvin]
        )
        // Kevin's photo is fresh, so the work list skips him. Swift folds the Kelvin sign
        // to an ASCII `k`, so a Swift-folded key for `kelvin` is exactly this row.
        let kevin = AvatarRecord(
            email: "kevin@example.invalid",
            data: Self.png,
            mime: "image/png",
            isExternal: true,
            fetchedAt: Int64(Self.now.timeIntervalSince1970)
        )
        try await store.upsert(avatar: kevin, accountId: try #require(try await store.accounts().first).id)
        // Bounded, so a fetcher that loops ends its pass on the 403 and fails the counts
        // below instead of hanging the suite.
        await transport.stubSequence(
            .pathContains("avatars/image/"),
            Array(repeating: StubResponse.status(404), count: 10) + [.status(403)]
        )

        #expect(await fetcher.runPass() == 2)
        let asked = await Self.askedAddresses(transport)
        #expect(asked.count == 2, "one request per distinct sender, got \(asked.count)")
        // Compared by Unicode scalars: Swift's `==` treats U+212A as canonically equal to `K`.
        let scalars = Set(asked.map { Array($0.unicodeScalars) })
        #expect(scalars == Set(["Ö@example.invalid", kelvin].map { Array($0.unicodeScalars) }))

        #expect(await fetcher.runPass() == 0)
        #expect(await transport.sendCount == 2)

        #expect(try await store.avatar(for: "kevin@example.invalid") == kevin)
        #expect(try await store.avatar(for: "Ö@example.invalid")?.missing == true)
        #expect(try await store.avatar(for: kelvin)?.missing == true)
    }

    @Test("a photo stored for an address with a non-ASCII capital is found under the spelling the header uses")
    func nonASCIIPhotoReadsBack() async throws {
        let (store, transport, fetcher) = try await Self.fixture(senders: ["Ö@example.invalid"])
        await transport.stubSequence(
            .pathContains("avatars/image/"),
            [StubResponse(status: 200, body: Self.png, headers: ["Content-Type": "image/png"]), .status(403)]
        )

        #expect(await fetcher.runPass() == 1)
        #expect(await transport.sendCount == 1)
        #expect(try await store.avatar(for: "Ö@example.invalid")?.data == Self.png)
    }
}
