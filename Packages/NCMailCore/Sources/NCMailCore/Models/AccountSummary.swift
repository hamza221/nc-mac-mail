// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One account from `GET /ocs/v2.php/apps/mail/account/list`, the trimmed
/// listing Mail exposes to other apps — and the one account route that includes
/// delegated accounts.
///
/// Verified live (Mail 5.12):
/// `{"id":1,"email":"…","isDelegated":false,"aliases":[{"id":3,"email":"…","name":"…"}]}`
/// inside the OCS wrapper. The aliases are trimmed too — `email`, not the
/// `alias` key ``Alias`` reads — so they get their own type.
public struct AccountSummary: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let email: String?
    public let isDelegated: Bool
    public let aliases: [AliasSummary]

    public struct AliasSummary: Decodable, Sendable, Hashable, Identifiable {
        public let id: Int
        public let email: String?
        public let name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case isDelegated
        case aliases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        isDelegated = try container.decodeLenientBool(forKey: .isDelegated)
        aliases = try container.decodeArray(AliasSummary.self, forKey: .aliases)
    }
}
