// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// The share `POST /ocs/v2.php/apps/files_sharing/api/v1/shares` creates,
/// inside the OCS wrapper — how the composer turns a Files attachment into a
/// link.
///
/// Verified live (Nextcloud 36) with `{"path":"/…","shareType":3}`: the id is
/// the **string** `"2"`, `share_type` is the integer 3, and `url` is the public
/// link to paste. Only the fields the composer needs are modelled; the payload
/// carries ~40 more.
public struct ShareLink: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let shareType: Int?
    public let token: String?
    /// The public link, `https://…/s/{token}`.
    public let url: String?
    public let path: String?
    public let label: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case shareType = "share_type"
        case token
        case url
        case path
        case label
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Defensive: OCS APIs have moved between string and integer ids before.
        if let string = try? container.decode(String.self, forKey: .id) {
            id = string
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        shareType = try container.decodeIfPresent(Int.self, forKey: .shareType)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }
}
