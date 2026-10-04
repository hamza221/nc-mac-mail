// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// Whether the Teams surfaces show at all (ADR-0097): only when the login's `teams` row is
/// `ready`. No row yet, `empty` (the server has no Circles app) and a failure with no earlier
/// answer all hide them — "nothing shows" is the default, not something a server must earn.
nonisolated enum TeamsGate {
    static func isAvailable(_ row: ServerResultRecord?) -> Bool {
        guard let row, let payload = try? ServerResultPayload(payloadJSON: row.payloadJSON) else { return false }
        return payload.isReady
    }
}

/// One team, read out of `team.rawJSON` (the Circles object as the server sent it).
nonisolated struct TeamSummary: Sendable, Equatable, Identifiable {
    let remoteId: String
    let name: String
    let description: String
    let config: TeamConfig
    let population: Int
    /// The login's own level in the team (the circle's `initiator`); 0 when it only sees it.
    let myLevel: Int
    /// The login's `singleId`, which a member row carries too: how "this row is me" is told.
    let mySingleId: String?
    let ownerName: String?
    /// The server's link to the team in the web Teams app.
    let url: URL?
    let members: [TeamMemberSummary]

    var id: String { remoteId }

    init(record: TeamRecord, members: [TeamMemberRecord]) {
        let raw = (try? JSONDecoder().decode(RawTeam.self, from: Data(record.rawJSON.utf8))) ?? RawTeam()
        remoteId = record.remoteId
        name = record.displayName
        description = raw.description ?? ""
        config = TeamConfig(rawValue: raw.config ?? 0)
        population = raw.population ?? members.count
        myLevel = raw.initiator?.level ?? 0
        mySingleId = raw.initiator?.singleId
        ownerName = raw.owner?.displayName
        url = raw.url.flatMap(URL.init(string:))
        self.members = members.compactMap(TeamMemberSummary.init(record:)).sorted(by: TeamMemberSummary.precedes)
    }

    // The rules below are web Contacts' (`Circle` model, `MemberListItem.vue`), kept as they
    // are so a person sees the same buttons in both clients; the server enforces them anyway.

    var isOwner: Bool { myLevel == TeamMemberLevel.owner.rawValue }
    /// Rename, description and options: the owner or an admin, never on a personal team.
    var canEditSettings: Bool {
        (isOwner || myLevel == TeamMemberLevel.admin.rawValue) && !config.contains(.personal)
    }
    /// Add and remove members: moderators and up, or anyone when members may invite.
    var canManageMembers: Bool { myLevel >= TeamMemberLevel.moderator.rawValue || config.contains(.friend) }
    var canDelete: Bool { isOwner }
    /// The owner cannot leave; ownership has to move first.
    var canLeave: Bool { myLevel > 0 && !isOwner }

    func isSelf(_ member: TeamMemberSummary) -> Bool {
        mySingleId != nil && member.singleId == mySingleId
    }

    /// The levels the login may move a member to: below its own; an admin may also make
    /// admins; the owner may hand over ownership. Never the member's current level.
    func availableLevels(for member: TeamMemberSummary) -> [TeamMemberLevel] {
        var levels = TeamMemberLevel.allCases.filter { $0.rawValue < myLevel }
        if myLevel == TeamMemberLevel.admin.rawValue { levels.append(.admin) }
        if isOwner { levels.append(.owner) }
        return levels.filter { $0.rawValue != member.levelValue }
    }

    func canChangeLevel(of member: TeamMemberSummary) -> Bool {
        member.levelValue > 0 && !availableLevels(for: member).isEmpty && myLevel >= member.levelValue
            && canManageMembers && !(isOwner && isSelf(member))
    }

    func canRemove(_ member: TeamMemberSummary) -> Bool {
        canManageMembers && member.levelValue <= myLevel && !isSelf(member)
    }

    /// A join request a moderator can answer.
    func canAccept(_ member: TeamMemberSummary) -> Bool {
        member.isRequesting && canManageMembers
    }

    /// Web Contacts' team options, grouped and worded as its `PUBLIC_CIRCLE_CONFIG`.
    static let optionGroups: [(title: String, options: [(TeamConfig, String)])] = [
        (
            String(localized: "Invites"),
            [
                (.open, String(localized: "Anyone can request membership")),
                (.invite, String(localized: "Members need to accept invitation")),
                (
                    .request,
                    String(
                        localized:
                            "Memberships must be confirmed/accepted by a Moderator (requires \"Anyone can request membership\")"
                    )
                ),
                (.friend, String(localized: "Members can also invite")),
            ]
        ),
        (
            String(localized: "Membership"),
            [(.root, String(localized: "Prevent teams from being a member of another team"))]
        ),
        (String(localized: "Federation"), [(.federated, String(localized: "Allow federated members"))]),
        (String(localized: "Privacy"), [(.visible, String(localized: "Visible to everyone"))]),
    ]

    private struct RawTeam: Decodable {
        var description: String?
        var config: Int?
        var population: Int?
        var initiator: RawMember?
        var owner: RawMember?
        var url: String?
    }

    struct RawMember: Decodable {
        var level: Int?
        var displayName: String?
        var singleId: String?
    }
}

/// One member, read out of `teamMember.rawJSON`.
nonisolated struct TeamMemberSummary: Sendable, Equatable, Identifiable {
    /// The Circles member id the level and removal routes take.
    let memberId: String
    /// The user id, group id, address or team name.
    let userId: String
    let kind: TeamMemberType
    /// The raw level: 0 for a join request or an invitation not yet accepted.
    let levelValue: Int
    let singleId: String?
    let displayName: String
    /// `Member`, `Invited`, `Requesting`.
    let status: String

    var id: String { memberId }

    init?(record: TeamMemberRecord) {
        guard let raw = try? JSONDecoder().decode(RawMember.self, from: Data(record.rawJSON.utf8)), let id = raw.id
        else { return nil }
        memberId = id
        userId = raw.userId ?? ""
        kind = TeamMemberType(rawValue: raw.basedOn?.source ?? raw.userType ?? 1) ?? .user
        levelValue = raw.level ?? 1
        singleId = raw.singleId
        displayName = record.displayName ?? raw.displayName ?? userId
        status = raw.status ?? "Member"
    }

    var level: TeamMemberLevel? { TeamMemberLevel(rawValue: levelValue) }
    var isRequesting: Bool { status == "Requesting" }
    var isInvited: Bool { status == "Invited" }

    /// "Owner", "Moderator", … or the pending state.
    var levelTitle: String {
        if isRequesting { return String(localized: "Requesting to join") }
        if isInvited { return String(localized: "Invited") }
        return level?.title ?? String(localized: "Member")
    }

    var kindTitle: String {
        switch kind {
        case .user: String(localized: "User")
        case .group: String(localized: "Group")
        case .mail: String(localized: "Email")
        case .contact: String(localized: "Contact")
        case .team: String(localized: "Team")
        }
    }

    /// Owner first, then by level, then by name.
    static func precedes(_ lhs: TeamMemberSummary, _ rhs: TeamMemberSummary) -> Bool {
        if lhs.levelValue != rhs.levelValue { return lhs.levelValue > rhs.levelValue }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private struct RawMember: Decodable {
        var id: String?
        var userId: String?
        var userType: Int?
        var level: Int?
        var singleId: String?
        var status: String?
        var displayName: String?
        var basedOn: Source?
        struct Source: Decodable { var source: Int? }
    }
}

extension TeamMemberLevel {
    nonisolated var title: String {
        switch self {
        case .member: String(localized: "Member")
        case .moderator: String(localized: "Moderator")
        case .admin: String(localized: "Admin")
        case .owner: String(localized: "Owner")
        }
    }
}

/// One "Shared items" entry, from the `sharedItems` row.
nonisolated struct SharedItem: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    let mimeType: String?
    let fileId: Int?
    let date: Date
    let isIncoming: Bool

    static func items(_ row: ServerResultRecord?) -> [SharedItem]? {
        guard let row, let payload = try? ServerResultPayload(payloadJSON: row.payloadJSON) else { return nil }
        switch payload {
        case .empty: return []
        case .failed: return nil
        case .ready(let data):
            guard case .array(let entries) = data else { return [] }
            return entries.compactMap { entry in
                guard let fields = entry.objectValue, case .string(let name)? = fields["name"] else { return nil }
                let id = fields["id"]?.stringValue ?? name
                let time: Int = if case .int(let value)? = fields["time"] { value } else { 0 }
                return SharedItem(
                    id: id,
                    name: name,
                    path: fields["path"]?.stringValue ?? name,
                    isFolder: fields["itemType"]?.stringValue == "folder",
                    mimeType: fields["mimeType"]?.stringValue,
                    fileId: { if case .int(let value)? = fields["fileId"] { value } else { nil } }(),
                    date: Date(timeIntervalSince1970: TimeInterval(time)),
                    isIncoming: fields["direction"]?.stringValue == "incoming"
                )
            }
        }
    }

    /// The file in the web Files app (`/index.php/f/{fileId}`), the link web Contacts' panel
    /// opens.
    func webURL(server: URL) -> URL? {
        fileId.map { server.appending(path: "index.php/f/\($0)") }
    }
}

/// Which cards "Shared items" applies to: the system address book's, whose UID is the user
/// id (verified live: `UID:alice` in `z-server-generated--system`), and never the login's own.
nonisolated enum SharedItemsScope {
    static func userId(of record: ContactRecord, book: AddressBookRecord?, loginName: String) -> String? {
        guard let book, isSystemAddressBook(book), let uid = record.uid, !uid.isEmpty,
            uid.caseInsensitiveCompare(loginName) != .orderedSame
        else { return nil }
        return uid
    }

    static func isSystemAddressBook(_ book: AddressBookRecord) -> Bool {
        book.url.hasSuffix("/z-server-generated--system/") || book.url.hasSuffix("/z-server-generated--system")
    }
}
