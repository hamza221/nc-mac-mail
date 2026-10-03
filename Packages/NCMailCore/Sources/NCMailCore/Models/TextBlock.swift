// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One text block from `GET /api/textBlocks`, inside the `JSONEnvelope`.
///
/// Shape pinned by `text-blocks.json`, recorded after creating one:
/// `{"id":1,"owner":"admin","title":"…","content":"…","preview":"…"}`.
public struct TextBlock: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String?
    public let content: String?
    public let owner: String?
    public let preview: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case owner
        case preview
    }
}

/// One share from `GET /api/textBlocks/{id}/shares`, inside the `JSONEnvelope`.
///
/// Shape pinned by `text-block-shares.json`:
/// `{"id":1,"type":"group","shareWith":"admin","textBlockId":1,"displayName":"admin"}`.
/// Everything but `id` stays optional — and note that `GET /api/textBlockshares`
/// (all shares) answers the shared text **blocks**, not share records, so it
/// decodes as `[TextBlock]`.
public struct TextBlockShare: Decodable, Sendable, Hashable {
    public let id: Int?
    public let textBlockId: Int?
    public let shareWith: String?
    public let displayName: String?
    public let type: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case textBlockId
        case shareWith
        case displayName
        case type
    }
}
