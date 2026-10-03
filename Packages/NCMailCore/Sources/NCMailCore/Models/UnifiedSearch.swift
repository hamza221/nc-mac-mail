// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /ocs/v2.php/search/providers/{providerId}/search?term=`, inside the OCS
/// wrapper — the route the Smart Picker searches through.
///
/// Verified live (Nextcloud 36):
/// `{"name":"Files","isPaginated":true,"entries":[],"cursor":5}`. `cursor` is
/// whatever the provider uses — an int offset for files — so it stays `AnyJSON`
/// and is echoed back, never interpreted.
public struct UnifiedSearchResult: Decodable, Sendable, Hashable {
    public let name: String?
    public let isPaginated: Bool
    public let entries: [Entry]
    public let cursor: AnyJSON?

    /// One hit. The live result set was empty, so the element shape follows the
    /// OCS search API and every field is optional.
    public struct Entry: Decodable, Sendable, Hashable {
        public let thumbnailUrl: String?
        public let title: String?
        public let subline: String?
        public let resourceUrl: String?
        public let icon: String?
        public let rounded: Bool
        public let attributes: [String: AnyJSON]

        private enum CodingKeys: String, CodingKey {
            case thumbnailUrl
            case title
            case subline
            case resourceUrl
            case icon
            case rounded
            case attributes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            subline = try container.decodeIfPresent(String.self, forKey: .subline)
            resourceUrl = try container.decodeIfPresent(String.self, forKey: .resourceUrl)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            rounded = try container.decodeLenientBool(forKey: .rounded)
            attributes = try container.decodePHPDictionary(AnyJSON.self, forKey: .attributes)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isPaginated
        case entries
        case cursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isPaginated = try container.decodeLenientBool(forKey: .isPaginated)
        entries = try container.decodeArray(Entry.self, forKey: .entries)
        cursor = try container.decodeIfPresent(AnyJSON.self, forKey: .cursor)
    }
}
