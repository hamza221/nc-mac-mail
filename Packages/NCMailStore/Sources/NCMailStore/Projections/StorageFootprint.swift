// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// What one account costs on disk, for Settings › Storage.
///
/// The byte counts are of the stored text and blobs, not of the file: SQLite pages, the index
/// and the freelist are shared between accounts and cannot honestly be attributed to one.
/// ``MailStore/fileSizeOnDisk(fileManager:)`` gives the file total alongside.
public struct StorageFootprint: FetchableRecord, Decodable, Sendable, Equatable {
    public var messageCount: Int
    public var bodyCount: Int
    /// `sum(messageBody.byteSize)` — the sanitised HTML plus the plain alternative.
    public var bodyBytes: Int64
    /// Inline images the renderer has already pulled. Nothing else is stored.
    public var attachmentBytes: Int64

    public init(messageCount: Int, bodyCount: Int, bodyBytes: Int64, attachmentBytes: Int64) {
        self.messageCount = messageCount
        self.bodyCount = bodyCount
        self.bodyBytes = bodyBytes
        self.attachmentBytes = attachmentBytes
    }
}
