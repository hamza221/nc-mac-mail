// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The `teams` kind (gate + team/teamMember refresh), the team commands, and `sharedItems`
/// (ADR-0097), over the WS-37 recordings.
@Suite("Teams fetcher")
struct TeamsFetcherTests {
    static let capabilities = RequestMatcher.pathSuffix("/cloud/capabilities")
    static let members = RequestMatcher.pathSuffix("/members")
    static let circles = RequestMatcher.method("GET") && .pathSuffix("/apps/circles/circles")
    static let withMe = RequestMatcher("shares with me") { $0.url?.query?.contains("shared_with_me=true") == true }
    static let mine = RequestMatcher.pathSuffix("/files_sharing/api/v1/shares")

    /// The recorded capabilities with the `circles` entry taken out: the same server, as it
    /// answers once the Circles app is disabled.
    static func capabilitiesWithoutCircles() throws -> StubResponse {
        var root = try #require(
            try JSONSerialization.jsonObject(with: try FixtureBytes.data("capabilities.json")) as? [String: Any])
        var ocs = try #require(root["ocs"] as? [String: Any])
        var data = try #require(ocs["data"] as? [String: Any])
        var capabilities = try #require(data["capabilities"] as? [String: Any])
        #expect(capabilities.removeValue(forKey: "circles") != nil, "the recording must have had Circles")
        data["capabilities"] = capabilities
        ocs["data"] = data
        root["ocs"] = ocs
        return StubResponse(body: try JSONSerialization.data(withJSONObject: root))
    }

    static func stubCircles(_ transport: FakeTransport) async throws {
        await transport.stub(capabilities, with: try .fixture("capabilities.json"))
        await transport.stub(members, with: try .fixture("circle-members-ws37.json"))
        await transport.stub(circles, with: try .fixture("circles.json"))
    }

    @Test("without the circles capability the row is empty, no Circles route is called, and nothing is mirrored")
    func noCirclesHidesEverything() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.capabilities, with: try Self.capabilitiesWithoutCircles())

        await f.fetcher.request(kind: .teams, key: ServerResultKind.teamsKey)
        await f.fetcher.settle()

        #expect(try await f.payload(.teams, ServerResultKind.teamsKey) == .empty)
        #expect(await f.transport.sendCount == 1)
        #expect(try await f.seeded.store.teams(loginId: f.loginId).isEmpty)
    }

    @Test("with Circles the teams and their members land in team and teamMember")
    func teamsAndMembersAreMirrored() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        try await Self.stubCircles(f.transport)

        await f.fetcher.request(kind: .teams, key: ServerResultKind.teamsKey)
        await f.fetcher.settle()

        let teams = try await f.seeded.store.teams(loginId: f.loginId)
        #expect(!teams.isEmpty)
        #expect(try await f.payload(.teams, ServerResultKind.teamsKey) == .ready(.object(["count": .int(teams.count)])))
        let team = try #require(teams.first)
        #expect(team.displayName == "Fixture Team")
        #expect(team.rawJSON.contains("\"config\""))
        let members = try await f.seeded.store.teamMembers(teamId: try #require(team.id))
        // The recorded team holds the owner, a group named like the owner, a second user and
        // an address: four rows, the user and the group apart by their kind prefix.
        #expect(Set(members.map(\.userId)) == ["1:admin", "2:admin", "1:alice", "4:user@example.com"])
        #expect(members.first { $0.userId.hasPrefix("4:") }?.email == "user@example.com")
    }

    @Test("Circles disabled after a ready answer: the row turns empty and the teams go")
    func circlesRemovedLaterEmptiesTheMirror() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        try await Self.stubCircles(f.transport)
        await f.fetcher.request(kind: .teams, key: ServerResultKind.teamsKey)
        await f.fetcher.settle()
        #expect(try await f.seeded.store.teams(loginId: f.loginId).isEmpty == false)

        let later = FakeTransport()
        await later.stub(Self.capabilities, with: try Self.capabilitiesWithoutCircles())
        let fetcher = ServerResultFetcher(
            store: f.seeded.store, client: try MirrorTest.client(later), identity: MirrorTest.identity)
        await fetcher.request(kind: .teams, key: ServerResultKind.teamsKey, force: true)
        await fetcher.settle()

        #expect(try await f.payload(.teams, ServerResultKind.teamsKey) == .empty)
        #expect(try await f.seeded.store.teams(loginId: f.loginId).isEmpty)
    }

    @Test("a failure keeps the ready row and the mirrored teams")
    func failureKeepsTeams() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stubSequence(Self.capabilities, [try .fixture("capabilities.json"), .status(503)])
        await f.transport.stub(Self.members, with: try .fixture("circle-members-ws37.json"))
        await f.transport.stub(Self.circles, with: try .fixture("circles.json"))
        await f.fetcher.request(kind: .teams, key: ServerResultKind.teamsKey)
        await f.fetcher.settle()
        let before = try await f.seeded.store.teams(loginId: f.loginId)

        await f.fetcher.request(kind: .teams, key: ServerResultKind.teamsKey, force: true)
        await f.fetcher.settle()

        #expect(try await f.payload(.teams, ServerResultKind.teamsKey)?.isReady == true)
        #expect(try await f.seeded.store.teams(loginId: f.loginId) == before)
    }

    @Test("create posts the web dialog's body, then refreshes before answering")
    func createRefreshes() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(
            .method("POST") && .pathSuffix("/apps/circles/circles"), with: try .fixture("circle-created-ws37.json"))
        try await Self.stubCircles(f.transport)

        let outcome = await f.fetcher.run(.create(name: "Fixture WS37 team"))

        #expect(outcome.isSuccess)
        let post = try #require(await f.transport.requests.first)
        #expect(post.httpMethod == "POST")
        let body = try JSONDecoder().decode(AnyJSON.self, from: try #require(post.httpBody))
        #expect(
            body == .object(["name": .string("Fixture WS37 team"), "personal": .bool(false), "local": .bool(false)]))
        // The refresh ran inside the command: the rows are there when the outcome is.
        #expect(try await f.payload(.teams, ServerResultKind.teamsKey)?.isReady == true)
        #expect(try await f.seeded.store.teams(loginId: f.loginId).isEmpty == false)
    }

    @Test("member level, removal, config, add and accept hit the verified routes with the verified bodies")
    func memberRoutes() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(
            .method("PUT") && .pathSuffix("/m1/level"), with: try .fixture("circle-member-level-ws37.json"))
        await f.transport.stub(
            .method("DELETE") && .pathSuffix("/members/m1"), with: try .fixture("circle-member-removed-ws37.json"))
        await f.transport.stub(
            .method("PUT") && .pathSuffix("/t1/config"), with: try .fixture("circle-config-ws37.json"))
        await f.transport.stub(
            .method("PUT") && .pathSuffix("/t1/description"), with: try .fixture("circle-description-ws37.json"))
        await f.transport.stub(
            .method("POST") && .pathSuffix("/t1/members"), with: try .fixture("circle-member-added-ws37.json"))
        try await Self.stubCircles(f.transport)

        #expect(await f.fetcher.run(.setLevel(teamId: "t1", memberId: "m1", level: .moderator)).isSuccess)
        #expect(await f.fetcher.run(.removeMember(teamId: "t1", memberId: "m1")).isSuccess)
        #expect(await f.fetcher.run(.setConfig(teamId: "t1", config: TeamConfig.visible.rawValue)).isSuccess)
        #expect(await f.fetcher.run(.setDescription(teamId: "t1", description: "Hello")).isSuccess)
        #expect(await f.fetcher.run(.addMember(teamId: "t1", userId: "a@example.net", type: .mail)).isSuccess)
        await f.transport.stub(
            .method("PUT") && .pathSuffix("/t1/members/m2"), with: try .fixture("circle-member-level-ws37.json"))
        #expect(await f.fetcher.run(.acceptMember(teamId: "t1", memberId: "m2")).isSuccess)

        let writes = await f.transport.requests.filter { $0.httpMethod != "GET" }
        func body(_ index: Int) throws -> AnyJSON? {
            try writes[index].httpBody.map { try JSONDecoder().decode(AnyJSON.self, from: $0) }
        }
        #expect(writes[0].url?.path.hasSuffix("/ocs/v2.php/apps/circles/circles/t1/members/m1/level") == true)
        #expect(try body(0) == .object(["level": .int(4)]))
        #expect(writes[1].httpMethod == "DELETE")
        #expect(try body(2) == .object(["value": .int(8)]))
        #expect(try body(3) == .object(["value": .string("Hello")]))
        #expect(try body(4) == .object(["userId": .string("a@example.net"), "type": .int(4)]))
        #expect(writes[5].httpMethod == "PUT" && writes[5].httpBody == nil)
    }

    @Test("a refused edit comes back as the failure and refreshes nothing")
    func refusedEdit() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(.method("DELETE"), with: .status(400))

        let outcome = await f.fetcher.run(.delete(teamId: "t1"))

        #expect(!outcome.isSuccess)
        #expect(await f.transport.sendCount == 1)
        #expect(try await f.payload(.teams, ServerResultKind.teamsKey) == nil)
    }

    @Test("shared items: the user shares between the login and that user, newest first, both directions")
    func sharedItems() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        await f.transport.stub(Self.withMe, with: try .fixture("shares-with-me-ws37.json"))
        await f.transport.stub(Self.mine, with: try .fixture("shares-mine-ws37.json"))

        await f.fetcher.request(kind: .sharedItems, key: "alice")
        await f.fetcher.settle()

        guard case .ready(.array(let items))? = try await f.payload(.sharedItems, "alice") else {
            Issue.record("expected a ready list")
            return
        }
        let fields = items.compactMap(\.objectValue)
        #expect(fields.map { $0["name"] } == [.string("Fixture OCS send.eml"), .string("fixture.txt")])
        #expect(fields.allSatisfy { $0["direction"] == .string("outgoing") })
        #expect(fields.last?["fileId"] == .int(275))

        await f.fetcher.request(kind: .sharedItems, key: "nobody")
        await f.fetcher.settle()
        #expect(try await f.payload(.sharedItems, "nobody") == .empty)
    }

    @Test("a share received from the user is incoming, at the path it has in the login's tree")
    func incomingShare() throws {
        // The same recorded listing seen from the recipient's side: the owner is the user.
        let recorded = try JSONDecoder().decode(
            OCSResponse<AnyJSON>.self, from: try FixtureBytes.data("shares-mine-ws37.json"))
        let items = sharedItemsPayload(mine: .array([]), withMe: recorded.data, userId: "admin")
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.objectValue?["direction"] == .string("incoming") })
        #expect(items.last?.objectValue?["path"] == .string("/fixture.txt"))
    }

    @Test("offline: no team request and no row")
    func offline() async throws {
        let f = try await ServerResultFetcherTests.fixture()
        try await Self.stubCircles(f.transport)
        await f.fetcher.apply(conditions: MirrorConditions(isOffline: true))
        await f.fetcher.request(kind: .teams, key: ServerResultKind.teamsKey)
        await f.fetcher.settle()
        #expect(await f.transport.sendCount == 0)
        #expect(try await f.payload(.teams, ServerResultKind.teamsKey) == nil)
    }
}
