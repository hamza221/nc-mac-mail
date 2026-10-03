// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `POST /api/mailboxes/{id}/sync`.
///
/// The names lie in two ways that ADR-0015 explains and the sync engine works
/// around. `changedMessages` is every id you sent that still exists, not the
/// ones that changed; the server has no change detection. `newMessages` holds
/// thread heads only, so a second new message in one thread never appears and
/// the tail scan has to find it.
public struct SyncResponse: Decodable, Sendable {
    public let newMessages: [RawBacked<Envelope>]
    public let changedMessages: [RawBacked<Envelope>]
    /// `array_diff` of the ids you sent against the ids that still exist, so
    /// nothing you did not claim to know can ever come back here.
    public let vanishedMessages: [Int]
    public let stats: MailboxStats?

    private enum CodingKeys: String, CodingKey {
        case newMessages
        case changedMessages
        case vanishedMessages
        case stats
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newMessages = try container.decodeArray(RawBacked<Envelope>.self, forKey: .newMessages)
        changedMessages = try container.decodeArray(RawBacked<Envelope>.self, forKey: .changedMessages)
        vanishedMessages = try container.decodeArray(Int.self, forKey: .vanishedMessages)
        stats = try container.decodeIfPresent(MailboxStats.self, forKey: .stats)
    }
}

/// `GET /api/mailboxes/{id}/stats`, and the `stats` member of a sync response.
public struct MailboxStats: Decodable, Sendable, Hashable {
    public let total: Int
    public let unread: Int

    public init(total: Int, unread: Int) {
        self.total = total
        self.unread = unread
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case unread
    }
}
