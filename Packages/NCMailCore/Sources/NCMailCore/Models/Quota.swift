// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/accounts/{id}/quota`, inside the `JSONEnvelope`.
///
/// Verified live (Mail 5.12): `{"status":"success","data":{"usage":0,"limit":0}}`.
/// Horde reports both in kibibytes; a `limit` of 0 means the IMAP server set none.
public struct Quota: Decodable, Sendable, Hashable {
    public let usage: Int
    public let limit: Int

    private enum CodingKeys: String, CodingKey {
        case usage
        case limit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decodeIfPresent(Int.self, forKey: .usage) ?? 0
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 0
    }
}
