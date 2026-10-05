// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

/// The `POST/PUT /api/drafts` body for one draft, built from its three tables.
///
/// Pure, so the mapping can be tested without a transport.
enum OutboxRequest {
    /// - Parameters:
    ///   - remoteAccountId: the server's account id (ADR-0033: the row holds the local one).
    ///   - aliasRemoteId: the server id of the draft's alias, resolved by the caller.
    ///   - sendAt: overrides the row's, for the send path's pinned `sendAt`.
    ///   - isCreate: only a create carries `draftId` (the IMAP message the server expunges).
    static func body(
        draft: DraftRecord,
        recipients: [DraftRecipientRecord],
        attachments: [DraftAttachmentRecord],
        remoteAccountId: Int64,
        aliasRemoteId: Int64?,
        sendAt: Int64?,
        isCreate: Bool
    ) -> ComposeMessageRequest {
        func addressees(_ kind: String) -> [RecipientRequest] {
            recipients
                .filter { $0.kind == kind }
                .sorted { $0.position < $1.position }
                .map { RecipientRequest(label: $0.label, email: $0.email) }
        }
        return ComposeMessageRequest(
            accountId: Int(remoteAccountId),
            subject: draft.subject ?? "",
            bodyPlain: draft.bodyPlain,
            bodyHtml: draft.bodyHtml,
            editorBody: draft.editorBody,
            isHtml: draft.isHtml,
            smimeSign: draft.smimeSign,
            smimeEncrypt: draft.smimeEncrypt,
            to: addressees("to"),
            cc: addressees("cc"),
            bcc: addressees("bcc"),
            attachments: attachments.compactMap(payload),
            aliasId: aliasRemoteId.map { Int($0) },
            inReplyToMessageId: draft.inReplyToMessageId,
            smimeCertificateId: draft.smimeCertificateRemoteId.map { Int($0) },
            sendAt: sendAt.map { Int($0) },
            draftId: isCreate ? draft.replacesMessageId.map { Int($0) } : nil,
            requestMdn: draft.requestMdn,
            isPgpMime: draft.isPgpMime
        )
    }

    /// What the server's `AttachmentService::handleAttachments` reads for one attachment.
    ///
    /// A local upload is `{"type":"local","id":…}` once it has a server id and nothing before
    /// (the caller uploads first). Every other kind — a forwarded message, one of its
    /// attachments, a Files path — is `payloadJSON` verbatim, as the composer stored it.
    static func payload(_ attachment: DraftAttachmentRecord) -> AnyJSON? {
        if attachment.kind == "local" {
            guard let remoteId = attachment.remoteAttachmentId else { return nil }
            return localPayload(remoteId)
        }
        guard let data = attachment.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnyJSON.self, from: data)
    }

    static func localPayload(_ remoteAttachmentId: Int64) -> AnyJSON {
        .object(["type": .string("local"), "id": .int(Int(remoteAttachmentId))])
    }

    static func localPayloadJSON(_ remoteAttachmentId: Int64) -> String {
        #"{"type":"local","id":\#(remoteAttachmentId)}"#
    }
}
