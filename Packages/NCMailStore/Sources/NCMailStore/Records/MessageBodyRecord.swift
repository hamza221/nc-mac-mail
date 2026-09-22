// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import GRDB

/// A row of `messageBody`.
///
/// `html` is the server's sanitised fragment from `?plain=true`, never raw MIME and never the
/// server's iframe-resizer document ([ADR-0009](../../../../docs/decisions/0009-sanitised-html-not-raw-mime.md)).
public struct MessageBodyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "messageBody"

    public var messageId: Int64
    public var hasHtmlBody: Bool
    public var html: String?
    public var plainBody: String?
    public var signature: String?
    public var isSenderTrusted: Bool
    public var dkimValid: Bool?
    public var smimeJSON: String?
    public var phishingJSON: String?
    public var schedulingJSON: String?
    public var itinerariesJSON: String?
    public var unsubscribeUrl: String?
    public var unsubscribeMailto: String?
    public var isOneClickUnsubscribe: Bool
    public var dispositionNotificationTo: String?
    public var hasAiGeneratedHeader: Bool
    public var fetchedAt: Int64
    public var byteSize: Int64
    public var sanitiserGeneration: Int
    public var rawJSON: String
}

/// A body as the backfill has it, before the store decides its `messageId` and size.
///
/// `byteSize` is absent on purpose: the storage panel's total has to agree with what is
/// actually stored, so the store measures the text it is about to write rather than believing
/// a number the caller passed in.
public struct MessageBodyWrite: Sendable {
    public var hasHtmlBody: Bool
    public var html: String?
    public var plainBody: String?
    public var signature: String?
    public var isSenderTrusted: Bool
    public var dkimValid: Bool?
    public var smimeJSON: String?
    public var phishingJSON: String?
    public var schedulingJSON: String?
    public var itinerariesJSON: String?
    public var unsubscribeUrl: String?
    public var unsubscribeMailto: String?
    public var isOneClickUnsubscribe: Bool
    public var dispositionNotificationTo: String?
    public var hasAiGeneratedHeader: Bool
    public var fetchedAt: Int64
    public var sanitiserGeneration: Int
    public var rawJSON: String
    public var attachments: [AttachmentWrite]

    public init(
        fetchedAt: Int64,
        hasHtmlBody: Bool = false,
        html: String? = nil,
        plainBody: String? = nil,
        signature: String? = nil,
        isSenderTrusted: Bool = false,
        dkimValid: Bool? = nil,
        smimeJSON: String? = nil,
        phishingJSON: String? = nil,
        schedulingJSON: String? = nil,
        itinerariesJSON: String? = nil,
        unsubscribeUrl: String? = nil,
        unsubscribeMailto: String? = nil,
        isOneClickUnsubscribe: Bool = false,
        dispositionNotificationTo: String? = nil,
        hasAiGeneratedHeader: Bool = false,
        sanitiserGeneration: Int = 1,
        rawJSON: String = "{}",
        attachments: [AttachmentWrite] = []
    ) {
        self.fetchedAt = fetchedAt
        self.hasHtmlBody = hasHtmlBody
        self.html = html
        self.plainBody = plainBody
        self.signature = signature
        self.isSenderTrusted = isSenderTrusted
        self.dkimValid = dkimValid
        self.smimeJSON = smimeJSON
        self.phishingJSON = phishingJSON
        self.schedulingJSON = schedulingJSON
        self.itinerariesJSON = itinerariesJSON
        self.unsubscribeUrl = unsubscribeUrl
        self.unsubscribeMailto = unsubscribeMailto
        self.isOneClickUnsubscribe = isOneClickUnsubscribe
        self.dispositionNotificationTo = dispositionNotificationTo
        self.hasAiGeneratedHeader = hasAiGeneratedHeader
        self.sanitiserGeneration = sanitiserGeneration
        self.rawJSON = rawJSON
        self.attachments = attachments
    }

    /// What goes in the `body` column of the search index.
    ///
    /// The plain alternative when the message has one, because it is already text. Otherwise
    /// the markup is stripped: indexing `<div>` and `style` would put tag names in everybody's
    /// results for a search on `div`.
    var indexedText: String {
        if let plainBody, !plainBody.isEmpty { return plainBody }
        guard let html else { return "" }
        return MessageBodyWrite.strippingMarkup(html)
    }

    /// Tags removed, and the contents of `<style>` and `<script>` removed with them.
    ///
    /// Dropping the elements as well as the tags is not tidiness. The server's sanitiser keeps
    /// `<style>`, and a marketing email carries kilobytes of it: measured on a recorded body,
    /// the CSS was most of the indexed text, so the index cost three times the message and
    /// every one of those emails matched a search for `width` or `padding`.
    static func strippingMarkup(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var index = html.startIndex
        var skippingElement: String?

        while index < html.endIndex {
            guard html[index] == "<" else {
                if skippingElement == nil { out.append(html[index]) }
                index = html.index(after: index)
                continue
            }

            var cursor = html.index(after: index)
            var isClosing = false
            if cursor < html.endIndex, html[cursor] == "/" {
                isClosing = true
                cursor = html.index(after: cursor)
            }
            var name = ""
            while cursor < html.endIndex, html[cursor].isLetter || html[cursor].isNumber {
                name.append(html[cursor])
                cursor = html.index(after: cursor)
            }
            while cursor < html.endIndex, html[cursor] != ">" { cursor = html.index(after: cursor) }
            if cursor < html.endIndex { cursor = html.index(after: cursor) }

            let element = name.lowercased()
            if let skipped = skippingElement {
                if isClosing && element == skipped { skippingElement = nil }
            } else if !isClosing && (element == "style" || element == "script") {
                skippingElement = element
            }
            out.append(" ")
            index = cursor
        }
        // The five predefined entities are the only ones the server's sanitiser emits.
        return
            out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A row of `attachment`. Metadata in v1; `data` is filled only for inline images the
/// renderer has already pulled, so a message read offline still shows its own pictures.
public struct AttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "attachment"

    public var messageId: Int64
    public var attachmentId: String
    public var isInline: Bool
    public var fileName: String?
    public var mime: String?
    public var size: Int64?
    public var cid: String?
    public var disposition: String?
    public var isImage: Bool
    public var isCalendarEvent: Bool
    public var downloadUrl: String?
    public var data: Data?
    public var fetchedAt: Int64?
}

/// An attachment's metadata, as it arrives with a body.
public struct AttachmentWrite: Sendable, Equatable {
    public var attachmentId: String
    public var isInline: Bool
    public var fileName: String?
    public var mime: String?
    public var size: Int64?
    public var cid: String?
    public var disposition: String?
    public var isImage: Bool
    public var isCalendarEvent: Bool
    public var downloadUrl: String?

    public init(
        attachmentId: String,
        isInline: Bool = false,
        fileName: String? = nil,
        mime: String? = nil,
        size: Int64? = nil,
        cid: String? = nil,
        disposition: String? = nil,
        isImage: Bool = false,
        isCalendarEvent: Bool = false,
        downloadUrl: String? = nil
    ) {
        self.attachmentId = attachmentId
        self.isInline = isInline
        self.fileName = fileName
        self.mime = mime
        self.size = size
        self.cid = cid
        self.disposition = disposition
        self.isImage = isImage
        self.isCalendarEvent = isCalendarEvent
        self.downloadUrl = downloadUrl
    }
}
