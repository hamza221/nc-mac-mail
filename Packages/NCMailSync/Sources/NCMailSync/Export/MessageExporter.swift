// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailNet
public import NCMailStore

/// What ``MessageExporter`` writes to disk for one message.
public enum MessageExport: Sendable, Equatable {
    /// The whole message as RFC 822 (`GET /api/messages/{id}/export`).
    case eml
    /// Every attachment as one zip (`GET /api/messages/{id}/attachments`).
    case attachmentsZip
    /// One attachment, served from the mirror when its bytes are already there.
    case attachment(id: String)
}

/// Writes a message, its attachments or one attachment to a file the user picked, so a
/// view saving a download never talks to the network itself.
///
/// Keyed by the LOCAL message id; the remote id is resolved through the store. The file
/// appears at `url` whole or not at all: bytes land in a temporary file beside it and are
/// renamed into place.
public actor MessageExporter {
    let store: MailStore
    let client: MailClient

    public init(store: MailStore, client: MailClient) {
        self.store = store
        self.client = client
    }

    /// - Throws: ``MailError/notFound`` when the message is no longer in the mirror, the
    ///   request's ``MailError`` otherwise, or the file system's error writing `url`.
    public func export(_ what: MessageExport, messageId: Int64, to url: URL) async throws {
        guard let message = try await store.message(id: messageId) else { throw MailError.notFound }
        let remoteId = Int(message.remoteId)
        let data: Data
        switch what {
        case .eml:
            data = try await client.bytes(.exportMessage(id: remoteId)).0
        case .attachmentsZip:
            data = try await client.bytes(.attachmentsZip(messageId: remoteId)).0
        case .attachment(let attachmentId):
            if let mirrored = try await store.body(messageId: messageId)?.attachments
                .first(where: { $0.attachmentId == attachmentId })?.data
            {
                data = mirrored
            } else {
                data = try await client.bytes(.attachment(messageId: remoteId, attachmentId: attachmentId)).0
            }
        }
        try Self.writeAtomically(data, to: url)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try data.write(to: temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
