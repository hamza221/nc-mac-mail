// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The Teams gate, the team and member reading over the WS-37 recordings, web Contacts'
/// permission rules, and "Shared items".
@Suite("Teams listing")
@MainActor
struct TeamsListingTests {
    private static let identity = ServerIdentity(serverURL: "https://cloud.example.com", loginName: "admin")

    private static func row(_ payload: String) -> ServerResultRecord {
        ServerResultRecord(
            loginId: 1, kind: "teams", key: ServerResultKind.teamsKey, payloadJSON: payload, fetchedAt: 1)
    }

    /// The recorded objects under `ocs.data`, each as JSON text.
    private static func recorded(_ fixture: String) throws -> [[String: Any]] {
        let root = try #require(
            try JSONSerialization.jsonObject(with: try FixtureBytes.data(fixture)) as? [String: Any])
        let data = (root["ocs"] as? [String: Any])?["data"]
        return try #require(data as? [[String: Any]])
    }

    private static func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// The recorded team and members, with the singleIds and the login's level set apart —
    /// the recorder scrubs every id to the same token, which would make everyone "me".
    private static func team(myLevel: Int, config: Int = 0) throws -> TeamSummary {
        var circle = try #require(try recorded("circles.json").first)
        var initiator = try #require(circle["initiator"] as? [String: Any])
        initiator["level"] = myLevel
        initiator["singleId"] = "me"
        circle["initiator"] = initiator
        circle["config"] = config
        let members = try recorded("circle-members-ws37.json").enumerated().map { index, raw in
            var member = raw
            member["id"] = "m\(index)"
            member["singleId"] =
                member["userId"] as? String == "admin" && member["userType"] as? Int == 1 ? "me" : "s\(index)"
            return TeamMemberRecord(
                teamId: 1, userId: "\(index)", displayName: member["displayName"] as? String,
                rawJSON: try text(member))
        }
        let record = TeamRecord(
            id: 1, loginId: 1, remoteId: "t1", displayName: circle["displayName"] as? String ?? "",
            rawJSON: try text(circle),
            fetchedAt: 1)
        return TeamSummary(record: record, members: members)
    }

    // MARK: The gate

    @Test func nothingShowsWithoutAReadyTeamsRow() {
        #expect(!TeamsGate.isAvailable(nil), "never answered: hidden")
        #expect(!TeamsGate.isAvailable(Self.row(#"{"status":"empty"}"#)), "no Circles app: hidden")
        #expect(!TeamsGate.isAvailable(Self.row(#"{"status":"failed","error":"transport"}"#)), "failure: hidden")
        #expect(TeamsGate.isAvailable(Self.row(#"{"status":"ready","data":{"count":0}}"#)), "Circles, no teams: shown")
    }

    @Test func theModelShowsNoTeamWhileTheRowSaysCirclesIsAbsent() async throws {
        let store = try MailStore.inMemory()
        let loginId = try #require(try await store.ensureLogin(Self.identity).id)
        // A team left in the table by an earlier answer must not leak through the gate.
        try await store.replaceTeams(
            [TeamRecord(loginId: loginId, remoteId: "t1", displayName: "Stale", fetchedAt: 1)], loginId: loginId)
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: ServerResultKind.teams.rawValue, key: ServerResultKind.teamsKey,
                payloadJSON: #"{"status":"empty"}"#, fetchedAt: 1))
        let model = TeamsModel(
            sessionId: AccountSession.identifier(server: Self.identity.serverURL, loginName: "admin"), store: store,
            fetcher: { nil })
        model.start()
        try await Self.waitUntil { model.loginId != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.isAvailable)
        #expect(model.teams.isEmpty)

        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: ServerResultKind.teams.rawValue, key: ServerResultKind.teamsKey,
                payloadJSON: #"{"status":"ready","data":{"count":1}}"#, fetchedAt: 2))
        try await Self.waitUntil { model.isAvailable }
        #expect(model.teams.map(\.name) == ["Stale"])
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    // MARK: Reading the recordings

    @Test func theRecordedTeamAndMembersRead() throws {
        let team = try Self.team(myLevel: 9)
        #expect(team.name == "Fixture Team")
        #expect(team.isOwner)
        #expect(team.url != nil)
        // Owner first; the group (userType 16, based on a group) reads as a group.
        #expect(team.members.first?.levelValue == 9)
        let kinds = Dictionary(team.members.map { ("\($0.kind)", $0.userId) }, uniquingKeysWith: { first, _ in first })
        #expect(kinds["group"] == "admin")
        #expect(kinds["mail"] == "user@example.com")
        #expect(team.members.allSatisfy { $0.status == "Member" })
    }

    // MARK: Permissions (web Contacts' rules)

    @Test func theOwnerManagesEveryoneButCannotLeaveOrDemoteThemselves() throws {
        let team = try Self.team(myLevel: 9)
        let me = try #require(team.members.first { team.isSelf($0) })
        let other = try #require(team.members.first { !team.isSelf($0) })
        #expect(team.canEditSettings && team.canDelete && !team.canLeave)
        #expect(!team.canChangeLevel(of: me))
        #expect(!team.canRemove(me))
        #expect(team.canRemove(other))
        #expect(team.availableLevels(for: other) == [.moderator, .admin, .owner])
    }

    @Test func aModeratorManagesMembersButNotSettings() throws {
        let team = try Self.team(myLevel: 4)
        let other = try #require(team.members.first { !team.isSelf($0) && $0.levelValue == 1 })
        #expect(team.canManageMembers)
        #expect(!team.canEditSettings && !team.canDelete && team.canLeave)
        #expect(team.availableLevels(for: other).isEmpty, "a moderator can only set member, which it already is")
        #expect(!team.canChangeLevel(of: other))
        #expect(team.canRemove(other))
        let owner = try #require(team.members.first { $0.levelValue == 9 })
        #expect(!team.canRemove(owner))
    }

    @Test func anAdminMayMakeAdmins() throws {
        let team = try Self.team(myLevel: 8)
        let other = try #require(team.members.first { !team.isSelf($0) && $0.levelValue == 1 })
        #expect(team.availableLevels(for: other) == [.moderator, .admin])
    }

    @Test func aMemberManagesNothingUnlessMembersMayInvite() throws {
        let plain = try Self.team(myLevel: 1)
        #expect(!plain.canManageMembers && !plain.canEditSettings && plain.canLeave)
        let friendly = try Self.team(myLevel: 1, config: TeamConfig.friend.rawValue)
        #expect(friendly.canManageMembers)
    }

    @Test func settingsSendOnlyWhatChanged() throws {
        let team = try Self.team(myLevel: 9)
        #expect(TeamSettingsChanges.commands(team: team, name: team.name, description: "", config: []).isEmpty)
        let commands = TeamSettingsChanges.commands(
            team: team, name: " Renamed ", description: "About", config: [.visible, .open])
        #expect(
            commands == [
                .rename(teamId: "t1", name: "Renamed"), .setDescription(teamId: "t1", description: "About"),
                .setConfig(teamId: "t1", config: 24),
            ])
    }

    @Test func emailMembersNeedSomethingLikeAnAddress() {
        #expect(AddTeamMemberSheet.looksLikeAddress("a@example.net"))
        #expect(!AddTeamMemberSheet.looksLikeAddress("a@example"))
        #expect(!AddTeamMemberSheet.looksLikeAddress("@example.net"))
        #expect(!AddTeamMemberSheet.looksLikeAddress("a@b@example.net"))
    }

    // MARK: Shared items

    @Test func sharedItemsApplyToOtherUsersOfTheSystemAddressBook() {
        let system = AddressBookRecord(
            loginId: 1, url: "https://x.example/remote.php/dav/addressbooks/users/admin/z-server-generated--system/",
            isReadOnly: true)
        let own = AddressBookRecord(
            loginId: 1, url: "https://x.example/remote.php/dav/addressbooks/users/admin/contacts/")
        let alice = ContactRecord(addressBookId: 1, href: "/a.vcf", uid: "alice", vcard: "", syncedAt: 0)
        let me = ContactRecord(addressBookId: 1, href: "/m.vcf", uid: "Admin", vcard: "", syncedAt: 0)
        #expect(SharedItemsScope.userId(of: alice, book: system, loginName: "admin") == "alice")
        #expect(SharedItemsScope.userId(of: me, book: system, loginName: "admin") == nil)
        #expect(SharedItemsScope.userId(of: alice, book: own, loginName: "admin") == nil)
    }

    @Test func sharedItemsReadTheirRow() throws {
        let payload = #"""
            {"status":"ready","data":[{"id":"19","name":"a.eml","path":"/a.eml","itemType":"file","mimeType":"message/rfc822","fileId":273,"time":1791128490,"direction":"outgoing"},{"id":"3","name":"Docs","path":"/Docs","itemType":"folder","mimeType":"httpd/unix-directory","fileId":12,"time":5,"direction":"incoming"}]}
            """#
        let items = try #require(SharedItem.items(Self.row(payload)))
        #expect(items.map(\.name) == ["a.eml", "Docs"])
        #expect(items[1].isFolder && items[1].isIncoming)
        #expect(
            items[0].webURL(server: try #require(URL(string: "https://cloud.example.com")))?.absoluteString
                == "https://cloud.example.com/index.php/f/273")
        #expect(SharedItem.items(Self.row(#"{"status":"empty"}"#)) == [])
        #expect(SharedItem.items(Self.row(#"{"status":"failed","error":"x"}"#)) == nil)
        #expect(SharedItem.items(nil) == nil)
    }
}
