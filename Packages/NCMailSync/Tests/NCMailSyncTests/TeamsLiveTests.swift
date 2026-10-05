// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// WS-37's live acceptance: a team created through the app's own command path shows up in
/// what the web client reads, members and options round-trip, "Shared items" answers, and
/// the scratch team is deleted at the end (ADR-0080). Off by default.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   NCMAIL_LIVE_SECOND_USER=alice swift test --build-system native --filter TeamsLive
/// ```
@Suite("Teams against a live server", .serialized)
struct TeamsLiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR"]

    @Test(.enabled(if: TeamsLiveTests.serverEnvironment != nil))
    func createATeamAndSeeItWhereTheWebClientLooks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw MirrorLiveMeasurementTests.LiveError.missingEnvironment }
        let second = environment["NCMAIL_LIVE_SECOND_USER"]

        let credentials = BasicCredentials(loginName: user, appPassword: password)
        let client = MailClient(server: server, credentials: credentials)
        let store = try MailStore.inMemory()
        let identity = ServerIdentity(serverURL: server, loginName: user)
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let fetcher = ServerResultFetcher(store: store, client: client, identity: identity)
        let clock = ContinuousClock()
        let name = "WS37 live \(UUID().uuidString.prefix(6))"

        // The gate answers ready on a server with Circles.
        var started = clock.now
        await fetcher.request(kind: .teams, key: ServerResultKind.teamsKey, force: true)
        await fetcher.settle()
        measured("teams refresh (capabilities + list + members) in \(clock.now - started)")
        let gate = try #require(
            try await store.serverResult(kind: "teams", key: ServerResultKind.teamsKey, loginId: loginId))
        #expect(try ServerResultPayload(payloadJSON: gate.payloadJSON).isReady)

        // Create through the command; the outcome returns after the rows landed.
        started = clock.now
        #expect(await fetcher.run(.create(name: name)).isSuccess)
        measured("create + refresh in \(clock.now - started)")
        let team = try #require(try await store.teams(loginId: loginId).first { $0.displayName == name })
        do {
            try await exercise(team, fetcher: fetcher, client: client, store: store, loginId: loginId, second: second)
        } catch {
            _ = await fetcher.run(.delete(teamId: team.remoteId))
            throw error
        }

        // Delete, and the row goes.
        #expect(await fetcher.run(.delete(teamId: team.remoteId)).isSuccess)
        #expect(try await store.teams(loginId: loginId).contains { $0.remoteId == team.remoteId } == false)
    }

    private func exercise(
        _ team: TeamRecord, fetcher: ServerResultFetcher, client: MailClient, store: MailStore, loginId: Int64,
        second: String?
    ) async throws {
        let clock = ContinuousClock()

        // What web Contacts and the Teams app read: the same OCS list, asked independently.
        let web = try await client.get(.teams).data
        guard case .array(let listed) = web else {
            Issue.record("the circles list is not an array")
            return
        }
        #expect(listed.contains { $0.objectValue?["id"]?.stringValue == team.remoteId })

        // Options and description.
        #expect(await fetcher.run(.setConfig(teamId: team.remoteId, config: TeamConfig.visible.rawValue)).isSuccess)
        #expect(await fetcher.run(.setDescription(teamId: team.remoteId, description: "Live run")).isSuccess)
        let edited = try #require(try await store.teams(loginId: loginId).first { $0.remoteId == team.remoteId })
        #expect(edited.rawJSON.contains("\"config\":8"))
        #expect(edited.rawJSON.contains("Live run"))

        // An address member, promoted, then removed.
        #expect(
            await fetcher.run(.addMember(teamId: team.remoteId, userId: "ws37-live@example.net", type: .mail)).isSuccess
        )
        var members = try await store.teamMembers(teamId: try await currentId(store, loginId, team.remoteId))
        let address = try #require(members.first { $0.userId == "4:ws37-live@example.net" })
        let memberId = try #require(Self.memberId(address))
        #expect(await fetcher.run(.setLevel(teamId: team.remoteId, memberId: memberId, level: .moderator)).isSuccess)
        members = try await store.teamMembers(teamId: try await currentId(store, loginId, team.remoteId))
        #expect(members.first { $0.userId == "4:ws37-live@example.net" }?.rawJSON.contains("\"level\":4") == true)
        #expect(await fetcher.run(.removeMember(teamId: team.remoteId, memberId: memberId)).isSuccess)

        if let second {
            #expect(await fetcher.run(.addMember(teamId: team.remoteId, userId: second, type: .user)).isSuccess)
            members = try await store.teamMembers(teamId: try await currentId(store, loginId, team.remoteId))
            #expect(members.contains { $0.userId == "1:\(second)" })

            let started = clock.now
            await fetcher.request(kind: .sharedItems, key: second, force: true)
            await fetcher.settle()
            measured("shared items for one user in \(clock.now - started)")
            let row = try #require(try await store.serverResult(kind: "sharedItems", key: second, loginId: loginId))
            if case .failed(let error) = try ServerResultPayload(payloadJSON: row.payloadJSON) {
                Issue.record("shared items failed: \(error)")
            }
        }
    }

    /// Team rows are replaced on every refresh, so the local id moves; the remote id does not.
    private func currentId(_ store: MailStore, _ loginId: Int64, _ remoteId: String) async throws -> Int64 {
        try #require(try await store.teams(loginId: loginId).first { $0.remoteId == remoteId }?.id)
    }

    private static func memberId(_ record: TeamMemberRecord) -> String? {
        (try? JSONDecoder().decode(AnyJSON.self, from: Data(record.rawJSON.utf8)))?.objectValue?["id"]?.stringValue
    }

    private func measured(_ text: String) {
        FileHandle.standardError.write(Data("[ws37-live] \(text)\n".utf8))
    }
}
