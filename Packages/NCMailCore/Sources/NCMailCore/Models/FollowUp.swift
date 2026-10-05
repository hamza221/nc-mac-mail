// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `POST /api/follow-up/check-message-ids`, inside the `JSONEnvelope`.
///
/// Verified live (Mail 5.12): `{"status":"success","data":{"wasFollowedUp":[]}}`.
/// The array holds the subset of the submitted message ids that already got a
/// reply, so the client can drop them from the follow-up list.
public struct FollowUpCheck: Decodable, Sendable, Hashable {
    public let wasFollowedUp: [Int]

    private enum CodingKeys: String, CodingKey {
        case wasFollowedUp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wasFollowedUp = try container.decodeArray(Int.self, forKey: .wasFollowedUp)
    }
}
