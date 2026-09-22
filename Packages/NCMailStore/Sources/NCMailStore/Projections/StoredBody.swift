// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Everything the message view needs to render, from one read transaction.
///
/// The body and its attachments are always wanted together — the renderer resolves `cid:`
/// references against the attachment list before it hands the document to the WebView — so
/// they are fetched together rather than in two round trips through the queue.
public struct StoredBody: Sendable, Equatable {
    public var body: MessageBodyRecord
    public var attachments: [AttachmentRecord]

    public init(body: MessageBodyRecord, attachments: [AttachmentRecord]) {
        self.body = body
        self.attachments = attachments
    }
}
