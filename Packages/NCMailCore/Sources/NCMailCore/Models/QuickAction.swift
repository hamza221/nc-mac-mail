// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One action chain from `GET /api/quick-actions`, inside the `JSONEnvelope`.
///
/// Verified live (Mail 5.12):
/// `{"id":1,"name":"…","accountId":1,"actionSteps":[…]}`.
public struct QuickAction: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String?
    public let accountId: Int?
    public let actionSteps: [ActionStep]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case accountId
        case actionSteps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        accountId = try container.decodeIfPresent(Int.self, forKey: .accountId)
        actionSteps = try container.decodeArray(ActionStep.self, forKey: .actionSteps)
    }
}

/// One step of a ``QuickAction``, also the payload of the `/api/action-step`
/// routes.
///
/// Verified live: `{"id":2,"name":"moveThread","order":2,"actionId":1,
/// "tagId":null,"mailboxId":3}`. `name` is one of the server's step kinds
/// (`markAsSpam`, `applyTag`, `snooze`, `moveThread`, `deleteThread`,
/// `markAsRead`, `markAsUnread`, `markAsImportant`, `markAsFavorite`);
/// `tagId` is set for `applyTag` and `mailboxId` for `moveThread`.
public struct ActionStep: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String?
    public let order: Int?
    public let actionId: Int?
    public let tagId: Int?
    public let mailboxId: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case order
        case actionId
        case tagId
        case mailboxId
    }
}
