// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One Smart Picker provider from `GET /ocs/v2.php/references/providers`,
/// inside the OCS wrapper.
///
/// Verified live (Nextcloud 36): `{"id":"calendar","title":"Calendar",
/// "icon_url":"…","order":20}`, with `search_providers_ids` present only on
/// providers that are searched through the unified-search routes.
public struct ReferenceProvider: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let iconUrl: String?
    public let order: Int?
    /// The unified-search provider ids to query for this picker entry; a
    /// provider without one resolves links but cannot be searched.
    public let searchProviderIds: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case iconUrl = "icon_url"
        case order
        case searchProviderIds = "search_providers_ids"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
        order = try container.decodeIfPresent(Int.self, forKey: .order)
        searchProviderIds = try container.decodeArray(String.self, forKey: .searchProviderIds)
    }
}
