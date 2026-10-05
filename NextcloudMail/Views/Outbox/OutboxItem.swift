// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// One `outboxMessage` row as the Outbox list shows it (§4.9): recipients, subject, and the
/// detail line the server's `status` decides.
///
/// Pure, so the status mapping is tested without a view.
nonisolated struct OutboxItem: Identifiable, Equatable, Sendable {
    /// The server's `LocalMessage::STATUS_*` values the list distinguishes.
    enum Status: Equatable, Sendable {
        /// Waiting for its send time (`STATUS_RAW`).
        case pending
        /// Sent, but the copy to Sent failed (`STATUS_IMAP_SENT_MAILBOX_FAIL`, 11).
        case sentCopyFailed
        /// SMTP refused it (`STATUS_SMPT_SEND_FAIL`, 10).
        case serverError
        /// Anything else the server marked as not sent.
        case notSent
    }

    struct Recipient: Decodable, Equatable, Sendable {
        let kind: String
        let email: String
        let label: String?
    }

    struct Attachment: Decodable, Equatable, Sendable {
        let id: Int
        let fileName: String?
        let mimeType: String?
        let type: String?
    }

    let id: Int64
    let accountId: Int64
    let subject: String
    let recipients: [Recipient]
    let attachments: [Attachment]
    let sendAt: Date?
    let status: Status

    init(_ record: OutboxMessageRecord) {
        id = record.id ?? 0
        accountId = record.accountId
        subject = record.subject ?? ""
        recipients = Self.decode([Recipient].self, record.recipientsJSON) ?? []
        attachments = Self.decode([Attachment].self, record.attachmentsJSON) ?? []
        sendAt = record.sendAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        status = Self.status(rawJSON: record.rawJSON, failed: record.failed)
    }

    /// "To+Cc+Bcc localized list", names where the server has them.
    var recipientLine: String {
        recipients.map { $0.label?.isEmpty == false ? $0.label ?? $0.email : $0.email }
            .formatted(.list(type: .and))
    }

    var displaySubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No subject") : subject
    }

    /// Sent-copy failures cannot be edited: the message already left (§4.9).
    var canEdit: Bool { status != .sentCopyFailed }
    var canSendNow: Bool { status == .pending || status == .notSent }
    var canCopyToSent: Bool { status == .sentCopyFailed }

    static func status(rawJSON: String, failed: Bool) -> Status {
        struct Raw: Decodable { let status: Int? }
        let code = decode(Raw.self, rawJSON)?.status
        switch code {
        case 11: return .sentCopyFailed
        case 10: return .serverError
        case nil, 0: return failed ? .notSent : .pending
        default: return .notSent
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
