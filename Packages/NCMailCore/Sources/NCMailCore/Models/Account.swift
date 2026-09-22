// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A mail account as `GET /api/accounts` reports it.
///
/// Only the fields v1 reads are modelled. Everything else survives in the
/// `RawBacked` wrapper and, through it, in `account.rawJSON`.
///
/// Every special mailbox id is optional: a freshly provisioned account has
/// none, and the live test server has no archive mailbox at all. A triage
/// action whose destination is nil is disabled, not force-unwrapped.
public struct Account: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let emailAddress: String
    public let order: Int

    public let draftsMailboxId: Int?
    public let sentMailboxId: Int?
    public let trashMailboxId: Int?
    public let archiveMailboxId: Int?
    public let snoozeMailboxId: Int?
    public let junkMailboxId: Int?

    public let showSubscribedOnly: Bool
    public let quotaPercentage: Int?
    /// True when this account belongs to another user and is shared with us
    /// through `DelegationService`. Absent before Mail 5.x.
    public let isDelegated: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case emailAddress
        case order
        case draftsMailboxId
        case sentMailboxId
        case trashMailboxId
        case archiveMailboxId
        case snoozeMailboxId
        case junkMailboxId
        case showSubscribedOnly
        case quotaPercentage
        case isDelegated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        draftsMailboxId = try container.decodeIfPresent(Int.self, forKey: .draftsMailboxId)
        sentMailboxId = try container.decodeIfPresent(Int.self, forKey: .sentMailboxId)
        trashMailboxId = try container.decodeIfPresent(Int.self, forKey: .trashMailboxId)
        archiveMailboxId = try container.decodeIfPresent(Int.self, forKey: .archiveMailboxId)
        snoozeMailboxId = try container.decodeIfPresent(Int.self, forKey: .snoozeMailboxId)
        junkMailboxId = try container.decodeIfPresent(Int.self, forKey: .junkMailboxId)
        showSubscribedOnly = try container.decodeLenientBool(forKey: .showSubscribedOnly)
        quotaPercentage = try container.decodeIfPresent(Int.self, forKey: .quotaPercentage)
        isDelegated = try container.decodeLenientBool(forKey: .isDelegated)
    }
}
