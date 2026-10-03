// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One delegation: an element of `GET /api/delegations/{accountId}` (a bare
/// array) and the bare body `POST /api/delegations/{accountId}` answers with
/// HTTP 201.
///
/// Verified live (Mail 5.12), granting account 1 to `alice` and revoking it:
/// `{"id":1,"accountId":1,"userId":"alice","displayName":"alice"}`.
public struct AccountDelegate: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let accountId: Int
    public let userId: String
    public let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case accountId
        case userId
        case displayName
    }
}
