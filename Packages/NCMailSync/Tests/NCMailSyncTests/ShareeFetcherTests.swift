// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The `sharees` kind: users and groups for a share dialog, keyed by the search term.
@Suite("Sharee fetcher")
struct ShareeFetcherTests {
    static let route = RequestMatcher.pathSuffix("/apps/files_sharing/api/v1/sharees")

    static func entry(_ shareWith: String, _ type: String, _ displayName: String) -> AnyJSON {
        .object(["shareWith": .string(shareWith), "type": .string(type), "displayName": .string(displayName)])
    }

    @Test("the recorded exact group match is a ready row, asked for users and groups by term")
    func recorded() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.route, with: try .fixture("sharees.json"))

        await f.fetcher.request(kind: .sharees, key: "admin")
        await f.fetcher.settle()

        #expect(try await f.payload(.sharees, "admin") == .ready(.array([Self.entry("admin", "group", "admin")])))
        let url = try #require(await f.transport.requests.first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "search", value: "admin")))
        #expect(items.contains(URLQueryItem(name: "itemType", value: "file")))
        #expect(items.filter { $0.name == "shareType[]" }.map(\.value) == ["0", "1"])
    }

    @Test("exact users, exact groups, then fuzzy users and groups; label becomes displayName")
    func ordering() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(
            Self.route,
            with: .json(
                #"""
                {"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{
                  "exact":{"users":[{"label":"Ann","value":{"shareType":0,"shareWith":"ann"}}],
                           "groups":[{"label":"Annex","value":{"shareType":1,"shareWith":"annex"}}]},
                  "users":[{"label":"Joanna","value":{"shareType":0,"shareWith":"jo"}}],
                  "groups":[{"label":"Planning","value":{"shareType":1,"shareWith":"plan"}}]}}}
                """#))

        await f.fetcher.request(kind: .sharees, key: "ann")
        await f.fetcher.settle()

        #expect(
            try await f.payload(.sharees, "ann")
                == .ready(
                    .array([
                        Self.entry("ann", "user", "Ann"), Self.entry("annex", "group", "Annex"),
                        Self.entry("jo", "user", "Joanna"), Self.entry("plan", "group", "Planning"),
                    ])))
    }

    @Test("no match is an empty row")
    func empty() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(
            Self.route,
            with: .json(
                #"{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"exact":{"users":[],"groups":[]},"users":[],"groups":[]}}}"#
            ))
        await f.fetcher.request(kind: .sharees, key: "zzz")
        await f.fetcher.settle()
        #expect(try await f.payload(.sharees, "zzz") == .empty)
    }

    @Test("a failure keeps the previous ready row")
    func failureKeepsRow() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stubSequence(Self.route, [try .fixture("sharees.json"), .status(503)])
        await f.fetcher.request(kind: .sharees, key: "admin")
        await f.fetcher.settle()
        let before = try await f.seeded.store.serverResult(kind: "sharees", key: "admin", loginId: f.loginId)

        await f.fetcher.request(kind: .sharees, key: "admin", force: true)
        await f.fetcher.settle()

        #expect(await f.transport.sendCount == 2)
        #expect(try await f.seeded.store.serverResult(kind: "sharees", key: "admin", loginId: f.loginId) == before)
    }

    @Test("offline: nothing is sent and no row appears")
    func offline() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.route, with: try .fixture("sharees.json"))
        await f.fetcher.apply(conditions: MirrorConditions(isOffline: true))
        await f.fetcher.request(kind: .sharees, key: "admin")
        await f.fetcher.settle()
        #expect(await f.transport.sendCount == 0)
        #expect(try await f.payload(.sharees, "admin") == nil)
    }

    @Test("two requests for the same term while one is in flight send one request")
    func join() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.route, with: try .fixture("sharees.json"))
        let (fetcher, gate) = try f.gated(holding: Self.route)
        await fetcher.request(kind: .sharees, key: "admin")
        await gate.waitForHeld()
        await fetcher.request(kind: .sharees, key: "admin")
        await gate.open()
        await fetcher.settle()
        #expect(await f.transport.sendCount == 1)
    }
}
