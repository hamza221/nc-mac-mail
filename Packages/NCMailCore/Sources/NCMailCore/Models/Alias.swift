// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One alias of an account, from `GET /api/accounts/{accountId}/aliases` and
/// echoed back by the create, update and delete calls.
///
/// Verified live (Mail 5.12) by creating one:
/// `{"id":1,"name":"…","alias":"…","signature":null,"provisioned":false,
///   "signatureMode":null,"smimeCertificateId":null}`.
/// There is no `accountId` in the payload — the route carries it.
/// `signatureMode` arrived as `null` on create and `0` on delete, so it is
/// optional and lenient like `Account`'s.
public struct Alias: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// The display name, nullable server-side.
    public let name: String?
    /// The address itself.
    public let alias: String
    public let signature: String?
    /// True when provisioning created it, which locks it in the UI.
    public let provisioned: Bool
    public let smimeCertificateId: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case alias
        case signature
        case provisioned
        case smimeCertificateId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        alias = try container.decode(String.self, forKey: .alias)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        provisioned = try container.decodeLenientBool(forKey: .provisioned)
        smimeCertificateId = try container.decodeIfPresent(Int.self, forKey: .smimeCertificateId)
    }
}
