// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

/// Teams (the Circles app) and "Shared items", the ADR-0067 way
/// ([ADR-0097](../../../../docs/decisions/0097-teams-are-mirrored-rows-and-online-commands.md)).
///
/// - The ``ServerResultKind/teams`` row is the gate *and* the refresh: it reads the
///   capabilities first and, without a `circles` entry, empties `team` and answers `empty`,
///   which is what keeps every Teams surface hidden. With one, it replaces `team` and
///   `teamMember` from `GET …/circles` and each `GET …/circles/{id}/members`.
/// - ``run(_:)`` performs one ``TeamCommand`` online (ADR-0068's shape): the server validates
///   membership rules a queued replay could not fix hours later. On success the rows are
///   refreshed before the outcome returns, so the view that awaited it already sees the
///   change in the store.
/// - ``ServerResultKind/sharedItems`` filters the two files_sharing listings down to the user
///   shares between the login and one user.
extension ServerResultFetcher {
    /// Runs one team edit and, when it worked, refreshes the team rows. Offline the request
    /// fails like any other; nothing is queued.
    public func run(_ command: TeamCommand) async -> CommandOutcome {
        do {
            try await perform(command)
        } catch let error as MailError {
            MirrorLog.mirror.info(
                "team command \(command.name, privacy: .public) failed: \(error.description, privacy: .public)")
            return .failure(error)
        } catch {
            MirrorLog.mirror.info("team command \(command.name, privacy: .public) failed: transport")
            return .failure(.transport(error))
        }
        await refreshTeamsNow()
        return .success
    }

    /// A forced ``ServerResultKind/teams`` fetch, awaited. A fetch already in flight started
    /// before the edit and may have read the old state, so it is waited out first.
    func refreshTeamsNow() async {
        let id = "\(ServerResultKind.teams.rawValue)|\(ServerResultKind.teamsKey)"
        if let running = inFlight[id] { await running.value }
        request(kind: .teams, key: ServerResultKind.teamsKey, force: true)
        await inFlight[id]?.value
    }

    private func perform(_ command: TeamCommand) async throws {
        switch command {
        case .create(let name):
            // Neither personal nor local: the web Contacts "Create team" dialog's defaults.
            _ = try await client.post(
                .createTeam,
                body: ["name": AnyJSON.string(name), "personal": .bool(false), "local": .bool(false)])
        case .rename(let teamId, let name):
            _ = try await client.put(.teamProperty(teamId: teamId, "name"), body: ["value": AnyJSON.string(name)])
        case .setDescription(let teamId, let description):
            _ = try await client.put(
                .teamProperty(teamId: teamId, "description"), body: ["value": AnyJSON.string(description)])
        case .setConfig(let teamId, let config):
            _ = try await client.put(.teamProperty(teamId: teamId, "config"), body: ["value": AnyJSON.int(config)])
        case .addMember(let teamId, let userId, let type):
            _ = try await client.post(
                .addTeamMember(teamId: teamId),
                body: ["userId": AnyJSON.string(userId), "type": .int(type.rawValue)])
        case .setLevel(let teamId, let memberId, let level):
            // Verified live: the body key is `level`, not the `value` the other PUTs take.
            _ = try await client.put(
                .teamMemberLevel(teamId: teamId, memberId: memberId), body: ["level": AnyJSON.int(level.rawValue)])
        case .removeMember(let teamId, let memberId):
            _ = try await client.delete(.teamMember(teamId: teamId, memberId: memberId))
        case .acceptMember(let teamId, let memberId):
            _ = try await client.put(.acceptTeamMember(teamId: teamId, memberId: memberId))
        case .leave(let teamId):
            _ = try await client.put(.leaveTeam(teamId: teamId))
        case .delete(let teamId):
            _ = try await client.delete(.team(teamId: teamId))
        }
    }

    // MARK: - The teams row

    func refreshTeams(loginId: Int64) async throws -> ServerResultPayload {
        let capabilities = try await client.get(.capabilitiesJSON).data
        guard hasCirclesCapability(capabilities) else {
            try await store.replaceTeams([], loginId: loginId)
            return .empty
        }
        let circles = teamObjects(try await client.get(.teams).data)
        // One members request per team, all at once: a person is in a handful of teams, and
        // each request is a third of a second on the test server (measured), so serial
        // requests are what the user would wait for.
        let client = client
        let members = try await withThrowingTaskGroup(of: (String, [AnyJSON]).self) { group in
            for id in circles.compactMap({ $0.string("id") }) {
                group.addTask {
                    do {
                        guard case .array(let list) = try await client.get(.teamMembers(teamId: id)).data else {
                            return (id, [])
                        }
                        return (id, list)
                    } catch MailError.forbidden, MailError.notFound {
                        // A team listed but not readable (visible, not joined): no members.
                        return (id, [])
                    }
                }
            }
            var members: [String: [AnyJSON]] = [:]
            for try await (id, list) in group { members[id] = list }
            return members
        }
        let fetchedAt = now()
        let rows = try await store.replaceTeams(
            try circles.compactMap { circle in
                guard let id = circle.string("id") else { return nil }
                return TeamRecord(
                    loginId: loginId,
                    remoteId: id,
                    displayName: circle.string("displayName") ?? circle.string("name") ?? id,
                    rawJSON: try MirrorMapping.jsonText(AnyJSON.object(circle)),
                    fetchedAt: fetchedAt
                )
            },
            loginId: loginId
        )
        for row in rows {
            guard let teamId = row.id else { continue }
            try await store.replaceTeamMembers(
                try teamMemberRecords(members[row.remoteId] ?? [], teamId: teamId), teamId: teamId)
        }
        return .ready(.object(["count": .int(rows.count)]))
    }

    // MARK: - Shared items

    func sharedItems(with userId: String) async throws -> ServerResultPayload {
        guard !userId.isEmpty else { throw ServerResultError.unknownKey }
        let mine = try await client.get(.shares(sharedWithMe: false)).data
        let withMe = try await client.get(.shares(sharedWithMe: true)).data
        let items = sharedItemsPayload(mine: mine, withMe: withMe, userId: userId)
        return items.isEmpty ? .empty : .ready(.array(items))
    }
}

/// One team edit. Team and member ids are the server's strings (Circles has no integer ids).
public enum TeamCommand: Sendable, Equatable {
    case create(name: String)
    case rename(teamId: String, name: String)
    case setDescription(teamId: String, description: String)
    /// The whole `config` bit field (``TeamConfig``), as the web client sends it.
    case setConfig(teamId: String, config: Int)
    /// `userId` is the user or group id, the address, or the team id, per `type`.
    case addMember(teamId: String, userId: String, type: TeamMemberType)
    case setLevel(teamId: String, memberId: String, level: TeamMemberLevel)
    case removeMember(teamId: String, memberId: String)
    /// Confirms a join request (a member at level 0, status `Requesting`). Rejecting one is
    /// ``removeMember(teamId:memberId:)``, as in web Contacts.
    case acceptMember(teamId: String, memberId: String)
    case leave(teamId: String)
    case delete(teamId: String)

    /// For the log: the case, never an id or a name.
    var name: String {
        switch self {
        case .create: "create"
        case .rename: "rename"
        case .setDescription: "setDescription"
        case .setConfig: "setConfig"
        case .addMember: "addMember"
        case .setLevel: "setLevel"
        case .removeMember: "removeMember"
        case .acceptMember: "acceptMember"
        case .leave: "leave"
        case .delete: "delete"
        }
    }
}

/// Circles' member types (`Member::TYPE_*`), the values web Contacts sends.
public enum TeamMemberType: Int, Sendable, CaseIterable {
    case user = 1
    case group = 2
    case mail = 4
    case contact = 8
    case team = 16
}

/// Circles' member levels (`Member::LEVEL_*`).
public enum TeamMemberLevel: Int, Sendable, CaseIterable, Comparable {
    case member = 1
    case moderator = 4
    case admin = 8
    case owner = 9

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Circles' `config` bits that web Contacts offers in a team's settings, plus the ones that
/// decide whether a team is editable at all.
public struct TeamConfig: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let personal = TeamConfig(rawValue: 2)
    /// Managed by an app or the server, not the Teams UI; web Contacts does not edit it.
    public static let system = TeamConfig(rawValue: 4)
    public static let visible = TeamConfig(rawValue: 8)
    public static let open = TeamConfig(rawValue: 16)
    public static let invite = TeamConfig(rawValue: 32)
    public static let request = TeamConfig(rawValue: 64)
    public static let friend = TeamConfig(rawValue: 128)
    public static let root = TeamConfig(rawValue: 8192)
    public static let federated = TeamConfig(rawValue: 32768)
}

/// Whether `GET /ocs/v2.php/cloud/capabilities` (the OCS `data`) names the Circles app.
func hasCirclesCapability(_ data: AnyJSON) -> Bool {
    guard case .object(let capabilities)? = data.objectValue?["capabilities"] else { return false }
    return capabilities["circles"] != nil
}

/// The circles list's objects, each id once. A real server never repeats an id; a scrubbed
/// fixture does, and one duplicate must not fail the whole refresh on `UNIQUE(loginId,
/// remoteId)`.
func teamObjects(_ data: AnyJSON) -> [[String: AnyJSON]] {
    guard case .array(let items) = data else { return [] }
    var seen: Set<String> = []
    return items.compactMap { item in
        guard case .object(let fields) = item, let id = fields.string("id"), seen.insert(id).inserted else {
            return nil
        }
        return fields
    }
}

/// `teamMember` rows for one team. `userId` holds `"<source>:<id>"` — the member's kind
/// (``TeamMemberType``, from `basedOn.source`, which says "group" where `userType` says
/// "team") and its user id, group id, address or team name — because a user and a group can
/// share a name inside one team. The Circles member id the edit routes need stays in
/// `rawJSON`.
func teamMemberRecords(_ members: [AnyJSON], teamId: Int64) throws -> [TeamMemberRecord] {
    var seen: Set<String> = []
    return try members.compactMap { member in
        guard case .object(let fields) = member, let userId = fields.string("userId") else { return nil }
        let source = fields["basedOn"]?.objectValue?.int("source") ?? fields.int("userType") ?? 0
        let key = "\(source):\(userId)"
        guard seen.insert(key).inserted else { return nil }
        return TeamMemberRecord(
            teamId: teamId,
            userId: key,
            displayName: fields.string("displayName"),
            email: source == TeamMemberType.mail.rawValue ? userId : nil,
            rawJSON: try MirrorMapping.jsonText(AnyJSON.object(fields))
        )
    }
}

/// The user shares between the login and `userId`, newest first: what the login shared with
/// them (`share_with`) and what they shared with the login (`uid_owner`).
func sharedItemsPayload(mine: AnyJSON, withMe: AnyJSON, userId: String) -> [AnyJSON] {
    func items(_ list: AnyJSON, direction: String, match: String, pathKey: String) -> [(Int, AnyJSON)] {
        guard case .array(let shares) = list else { return [] }
        return shares.compactMap { share in
            guard case .object(let fields) = share, fields.int("share_type") == 0,
                fields.string(match) == userId, let path = fields.string(pathKey) ?? fields.string("path")
            else { return nil }
            let time = fields.int("stime") ?? 0
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return (
                time,
                .object([
                    "id": fields["id"].flatMap(\.stringValue).map(AnyJSON.string) ?? .null,
                    "name": .string(name),
                    "path": .string(path),
                    "itemType": fields.string("item_type").map(AnyJSON.string) ?? .null,
                    "mimeType": fields.string("mimetype").map(AnyJSON.string) ?? .null,
                    "fileId": fields.int("file_source").map(AnyJSON.int) ?? .null,
                    "time": .int(time),
                    "direction": .string(direction),
                ])
            )
        }
    }
    let all =
        items(mine, direction: "outgoing", match: "share_with", pathKey: "path")
        + items(withMe, direction: "incoming", match: "uid_owner", pathKey: "file_target")
    return all.sorted { $0.0 > $1.0 }.map(\.1)
}

extension Endpoint where Response == OCSResponse<AnyJSON> {
    private static func circlesPath(_ path: String = "") -> String { "ocs/v2.php/apps/circles/circles\(path)" }

    /// The capabilities as JSON: `Capabilities` names only the entries Mail reads, and the
    /// gate needs to know whether `circles` is there at all.
    static var capabilitiesJSON: Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "capabilities", method: .get, base: .server, encodedPath: "ocs/v2.php/cloud/capabilities",
            isRetryable: true)
    }

    /// `GET …/circles` — the teams the login belongs to (verified live, Nextcloud 36).
    static var teams: Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(name: "teams", method: .get, base: .server, encodedPath: circlesPath(), isRetryable: true)
    }

    static func teamMembers(teamId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.members", method: .get, base: .server, encodedPath: circlesPath("/\(escape(teamId))/members"),
            isRetryable: true)
    }

    /// `POST …/circles` `{name, personal, local}`.
    static var createTeam: Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(name: "teams.create", method: .post, base: .server, encodedPath: circlesPath(), isRetryable: false)
    }

    /// `PUT …/circles/{id}/{name|description|config}` `{value}`.
    static func teamProperty(teamId: String, _ property: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.\(property)", method: .put, base: .server,
            encodedPath: circlesPath("/\(escape(teamId))/\(property)"), isRetryable: false)
    }

    /// `POST …/circles/{id}/members` `{userId, type}`.
    static func addTeamMember(teamId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.addMember", method: .post, base: .server,
            encodedPath: circlesPath("/\(escape(teamId))/members"),
            isRetryable: false)
    }

    /// `PUT …/circles/{id}/members/{memberId}/level` `{level}`.
    static func teamMemberLevel(teamId: String, memberId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.level", method: .put, base: .server,
            encodedPath: circlesPath("/\(escape(teamId))/members/\(escape(memberId))/level"), isRetryable: false)
    }

    /// `DELETE …/circles/{id}/members/{memberId}`.
    static func teamMember(teamId: String, memberId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.removeMember", method: .delete, base: .server,
            encodedPath: circlesPath("/\(escape(teamId))/members/\(escape(memberId))"), isRetryable: false)
    }

    /// `PUT …/circles/{id}/members/{memberId}` — accept a join request (verified live).
    static func acceptTeamMember(teamId: String, memberId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.acceptMember", method: .put, base: .server,
            encodedPath: circlesPath("/\(escape(teamId))/members/\(escape(memberId))"), isRetryable: false)
    }

    /// `PUT …/circles/{id}/leave`.
    static func leaveTeam(teamId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.leave", method: .put, base: .server, encodedPath: circlesPath("/\(escape(teamId))/leave"),
            isRetryable: false)
    }

    /// `DELETE …/circles/{id}`.
    static func team(teamId: String) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: "teams.delete", method: .delete, base: .server, encodedPath: circlesPath("/\(escape(teamId))"),
            isRetryable: false)
    }

    /// `GET /ocs/v2.php/apps/files_sharing/api/v1/shares` — the login's own shares, or with
    /// `shared_with_me=true` the ones it received.
    static func shares(sharedWithMe: Bool) -> Endpoint<OCSResponse<AnyJSON>> {
        Endpoint(
            name: sharedWithMe ? "shares.withMe" : "shares.mine", method: .get, base: .server,
            encodedPath: "ocs/v2.php/apps/files_sharing/api/v1/shares",
            query: sharedWithMe ? [URLQueryItem(name: "shared_with_me", value: "true")] : [],
            isRetryable: true)
    }
}
