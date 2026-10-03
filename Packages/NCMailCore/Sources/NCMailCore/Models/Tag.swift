// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A user tag, which is an IMAP keyword the Mail app gives a name and a colour.
///
/// On an envelope these arrive as a dictionary keyed by ``imapLabel``, not as an
/// array, and an envelope with no tags carries `[]` because PHP serialises an
/// empty associative array as a JSON array. ``Envelope`` handles both.
public struct Tag: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let displayName: String
    /// The IMAP keyword, for example `$label1`. This is the dictionary key too.
    public let imapLabel: String
    /// A CSS colour. Short form (`#fff`) occurs.
    public let color: String?
    public let isDefaultTag: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case imapLabel
        case color
        case isDefaultTag
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        imapLabel = try container.decode(String.self, forKey: .imapLabel)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        isDefaultTag = try container.decodeLenientBool(forKey: .isDefaultTag)
    }
}
