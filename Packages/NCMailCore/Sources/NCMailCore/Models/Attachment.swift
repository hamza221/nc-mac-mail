// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One attachment, from either the envelope or the body.
///
/// The two are not the same shape. An envelope carries a reduced record with
/// `id`, `fileName`, `mime`, `downloadUrl` and `mimeUrl`; only the body endpoint
/// runs `enrichAttachment` and adds `size`, `cid`, `disposition`, `isImage` and
/// `isCalendarEvent`. Everything the envelope omits is therefore optional here.
///
/// ``id`` is a string. It is the MIME part path, so `"2"` and `"2.1"` are both
/// valid and neither is a number.
public struct Attachment: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    /// The IMAP uid of the message, not its `databaseId`. Present on the body
    /// shape only, and not the value to look a message up by.
    public let messageUid: Int?
    public let fileName: String?
    public let mime: String?
    public let size: Int?
    /// The Content-ID an inline image is referenced by from the HTML body.
    public let cid: String?
    public let disposition: String?
    public let downloadUrl: String?
    public let mimeUrl: String?
    public let isImage: Bool?
    public let isCalendarEvent: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId
        case fileName
        case mime
        case size
        case cid
        case disposition
        case downloadUrl
        case mimeUrl
        case isImage
        case isCalendarEvent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        messageUid = try container.decodeIfPresent(Int.self, forKey: .messageId)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        cid = try container.decodeIfPresent(String.self, forKey: .cid)
        disposition = try container.decodeIfPresent(String.self, forKey: .disposition)
        downloadUrl = try container.decodeIfPresent(String.self, forKey: .downloadUrl)
        mimeUrl = try container.decodeIfPresent(String.self, forKey: .mimeUrl)
        isImage = try container.decodeIfPresent(Bool.self, forKey: .isImage)
        isCalendarEvent = try container.decodeIfPresent(Bool.self, forKey: .isCalendarEvent)
    }
}
