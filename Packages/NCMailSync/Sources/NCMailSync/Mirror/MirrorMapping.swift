// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore
public import NCMailStore

/// Wire models in, store writes out. Four functions, no database, no network.
///
/// This is the whole of the translation layer ADR-0023 asks for, and it is `public` and
/// pure so that it can be tested against recorded fixtures without a `MailStore` — a
/// mapping bug and a transaction bug then fail different tests.
///
/// The writes are narrow on purpose. ``envelopeWrite(_:accountId:syncedAt:)`` produces an
/// `EnvelopeWrite`, never a `MessageRecord`: the record carries `bodyState`, so re-syncing
/// an envelope through it would reset every already-downloaded body to `missing` and the
/// mirror would re-fetch bodies forever without anything failing. Likewise
/// ``mailboxWrite(_:)`` does not set `isMirrored` and ``bodyWrite(_:html:fetchedAt:)`` does
/// not set `byteSize`; the store owns both.
public enum MirrorMapping {
    // MARK: - Account

    public static func accountWrite(_ account: RawBacked<Account>) throws -> AccountWrite {
        let value = account.value
        return AccountWrite(
            id: Int64(value.id),
            name: value.name,
            emailAddress: value.emailAddress,
            sortOrder: value.order,
            draftsMailboxId: value.draftsMailboxId.map(Int64.init),
            sentMailboxId: value.sentMailboxId.map(Int64.init),
            trashMailboxId: value.trashMailboxId.map(Int64.init),
            archiveMailboxId: value.archiveMailboxId.map(Int64.init),
            junkMailboxId: value.junkMailboxId.map(Int64.init),
            snoozeMailboxId: value.snoozeMailboxId.map(Int64.init),
            showSubscribedOnly: value.showSubscribedOnly,
            quotaPercentage: value.quotaPercentage,
            // The accounts payload has no signature field; the per-account route carries one
            // and WS-12 reads it. Writing nil here would blank a value already stored, so it
            // is left at the column default on insert and untouched on update.
            signature: nil,
            rawJSON: try jsonText(account)
        )
    }

    // MARK: - Mailbox

    /// `isSubscribed` and `isSelectable` come off the raw IMAP `attributes` array, which is
    /// the only place the server expresses either (ADR-0007). `isMirrored` is absent: the
    /// store derives it from `isSubscribed` so the rule lives in one place.
    public static func mailboxWrite(_ mailbox: RawBacked<Mailbox>) throws -> MailboxWrite {
        let value = mailbox.value
        return MailboxWrite(
            id: Int64(value.id),
            accountId: Int64(value.accountId),
            name: value.name,
            delimiter: value.delimiter.isEmpty ? nil : value.delimiter,
            displayName: value.displayName,
            specialRole: value.specialRole,
            specialUseJSON: try jsonText(value.specialUse),
            attributesJSON: try jsonText(value.attributes),
            isSubscribed: value.isSubscribed,
            isSelectable: value.isSelectable,
            syncInBackground: value.syncInBackground,
            unreadCount: value.unread,
            // The folder list carries no total. `stats` fills it, from the sync response or
            // from `GET /mailboxes/{id}/stats`, and both belong to WS-05.
            totalCount: nil,
            cacheBuster: value.cacheBuster,
            rawJSON: try jsonText(mailbox)
        )
    }

    // MARK: - Envelope

    /// - Parameter syncedAt: when this copy was taken, in unix seconds. Passed in rather
    ///   than read from the clock so the caller can stamp a whole page identically and a
    ///   test can stamp it predictably.
    public static func envelopeWrite(
        _ envelope: RawBacked<Envelope>,
        accountId: Int64,
        syncedAt: Int64
    ) throws -> EnvelopeWrite {
        let value = envelope.value
        var flags = NCMailStore.MessageFlags()
        flags.isSeen = value.flags.seen
        flags.isFlagged = value.flags.flagged
        flags.isAnswered = value.flags.answered
        flags.isDeleted = value.flags.deleted
        flags.isDraft = value.flags.draft
        flags.isForwarded = value.flags.forwarded
        flags.isImportant = value.flags.important
        flags.isJunk = value.flags.junk
        flags.isNotJunk = value.flags.notJunk
        flags.isMdnSent = value.flags.mdnSent
        // Two sources for one column. The `hasAttachments` flag is what the list row draws a
        // paperclip from, and the server sets it from the IMAP body structure; an envelope
        // that nonetheless lists attachments has them.
        flags.hasAttachments = value.flags.hasAttachments || !value.attachments.isEmpty
        flags.mentionsMe = value.mentionsMe
        flags.isEncrypted = value.encrypted
        flags.isImipMessage = value.imipMessage

        return EnvelopeWrite(
            id: Int64(value.id),
            mailboxId: Int64(value.mailboxId),
            accountId: accountId,
            sentAt: Int64(value.dateInt),
            syncedAt: syncedAt,
            uid: value.uid.map(Int64.init),
            messageId: value.messageId,
            threadRootId: value.threadRootId,
            inReplyTo: value.inReplyTo,
            referencesJSON: value.references.isEmpty ? nil : try jsonText(value.references),
            subject: value.subject,
            previewText: value.previewText,
            summary: value.summary,
            flags: flags,
            fromEmail: value.sender?.email,
            fromLabel: value.sender?.label,
            addresses: addresses(of: value),
            rawJSON: try jsonText(envelope)
        )
    }

    /// `messageAddress.email` is `NOT NULL`, so an entry with no address is dropped rather
    /// than stored as an empty string. That is a group address such as
    /// `undisclosed-recipients:;`, which is a label and nothing to look anybody up by.
    private static func addresses(of envelope: Envelope) -> [EnvelopeAddress] {
        var result: [EnvelopeAddress] = []
        func append(_ list: [Address], as kind: AddressKind) {
            for address in list {
                guard let email = address.email, !email.isEmpty else { continue }
                result.append(EnvelopeAddress(kind: kind, email: email, label: address.label))
            }
        }
        append(envelope.from, as: .from)
        append(envelope.to, as: .to)
        append(envelope.cc, as: .cc)
        append(envelope.bcc, as: .bcc)
        return result
    }

    // MARK: - Body

    /// - Parameter html: the sanitised fragment from `GET /messages/{id}/html?plain=true`,
    ///   or nil when the message has no HTML part and the second request was skipped. When
    ///   it is nil and the message does have an HTML part — the fragment 404'd while the
    ///   body did not — `body.body` is stored instead, because a message that renders from a
    ///   slightly staler copy beats a message that never renders.
    public static func bodyWrite(
        _ body: RawBacked<MessageBody>,
        html: String?,
        fetchedAt: Int64
    ) throws -> MessageBodyWrite {
        let value = body.value
        return MessageBodyWrite(
            fetchedAt: fetchedAt,
            hasHtmlBody: value.hasHtmlBody,
            html: value.hasHtmlBody ? (html ?? value.body) : nil,
            plainBody: value.hasHtmlBody ? nil : value.body,
            signature: value.signature,
            isSenderTrusted: value.isSenderTrusted,
            dkimValid: value.dkimValid,
            smimeJSON: try jsonText(optional: value.smime),
            phishingJSON: try jsonText(optional: value.phishingDetails),
            schedulingJSON: try jsonText(optional: value.scheduling),
            itinerariesJSON: try jsonText(optional: value.itineraries),
            unsubscribeUrl: value.unsubscribeUrl,
            unsubscribeMailto: value.unsubscribeMailto,
            isOneClickUnsubscribe: value.isOneClickUnsubscribe,
            dispositionNotificationTo: value.dispositionNotificationTo,
            hasAiGeneratedHeader: value.hasAiGeneratedHeader,
            sanitiserGeneration: MirrorMapping.sanitiserGeneration,
            rawJSON: try bodyRawJSON(body),
            attachments: attachmentWrites(of: value)
        )
    }

    /// The `/body` response with its `body` field removed.
    ///
    /// `rawJSON` exists so that a field the client does not model yet survives a sync
    /// (ADR-0020). `body` is the one field that is neither unmodelled nor small: it is
    /// stored in the `html` or `plainBody` column three lines above, and keeping the
    /// server's copy as well means every message's text is on disk twice. Measured on a
    /// full mirror of the live account: 4,785,035 bytes of `messageBody.rawJSON`, of which
    /// 4,447,526 were `body` — 93% of the column, and 41% of the whole database file.
    /// ADR-0032.
    private static func bodyRawJSON(_ body: RawBacked<MessageBody>) throws -> String {
        guard case .object(var fields) = body.json else { return try jsonText(body) }
        fields.removeValue(forKey: "body")
        return try jsonText(AnyJSON.object(fields))
    }

    /// Bumped when the server's sanitiser changes in a way that makes stored HTML worth
    /// re-fetching. `messageBody.sanitiserGeneration` records what each body was stored
    /// under, and Settings › Re-download is what acts on a bump (WS-12).
    public static let sanitiserGeneration = 1

    /// The two lists are merged, not concatenated. A part can appear in both `attachments`
    /// and `inlineAttachments`, and `attachment`'s primary key is
    /// `(messageId, attachmentId)`, so the inline copy is kept: it is the one carrying the
    /// `cid` the renderer resolves an `<img src="cid:…">` against.
    private static func attachmentWrites(of body: MessageBody) -> [AttachmentWrite] {
        var byId: [String: AttachmentWrite] = [:]
        var order: [String] = []
        func add(_ attachments: [NCMailCore.Attachment], isInline: Bool) {
            for attachment in attachments {
                if byId[attachment.id] == nil { order.append(attachment.id) }
                byId[attachment.id] = AttachmentWrite(
                    attachmentId: attachment.id,
                    isInline: isInline,
                    fileName: attachment.fileName,
                    mime: attachment.mime,
                    size: attachment.size.map(Int64.init),
                    cid: attachment.cid,
                    disposition: attachment.disposition,
                    isImage: attachment.isImage ?? false,
                    isCalendarEvent: attachment.isCalendarEvent ?? false,
                    downloadUrl: attachment.downloadUrl
                )
            }
        }
        add(body.attachments, isInline: false)
        add(body.inlineAttachments, isInline: true)
        return order.compactMap { byId[$0] }
    }

    // MARK: - JSON

    /// The `rawJSON` column's contents: everything the server sent for this object,
    /// including the fields no model names (ADR-0020).
    private static func jsonText<Value>(_ raw: RawBacked<Value>) throws -> String {
        String(decoding: try raw.rawJSON(), as: UTF8.self)
    }

    private static func jsonText(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Nil for both "the key was absent" and "the key was `null`", so the column reads the
    /// same either way rather than holding the four characters `null`.
    private static func jsonText(optional value: AnyJSON?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try jsonText(value)
    }
}
