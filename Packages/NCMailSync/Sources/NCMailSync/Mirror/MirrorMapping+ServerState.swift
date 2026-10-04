// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore
public import NCMailStore

/// The settings surface, wire to rows. Pure like the rest of ``MirrorMapping``: no store,
/// no network, testable against the recorded fixtures.
///
/// Where an entry lacks the one field its row cannot exist without — a trusted sender with
/// no address, a share with no recipient — the entry is dropped rather than stored as an
/// empty string that a view would then have to know to hide.
///
/// Most of these routes decode into plain models rather than `RawBacked` ones, so their rows
/// keep the column default for `rawJSON`; the accounts payload (aliases) and the outbox are
/// the two that carry the server's JSON.
extension MirrorMapping {
    // MARK: - Aliases

    /// The aliases embedded in one `GET /api/accounts` entry. The index route always embeds
    /// them (`AccountsController::index`), so the mirror needs no `GET …/aliases` per
    /// account, and the alias signatures arrive with them.
    public static func aliasRecords(_ account: RawBacked<Account>, accountId: Int64) throws -> [AliasRecord] {
        guard case .array(let entries)? = account.json.objectValue?["aliases"] else { return [] }
        return try entries.map { entry in
            let alias = try entry.decode(Alias.self)
            return AliasRecord(
                accountId: accountId,
                remoteId: Int64(alias.id),
                email: alias.alias,
                name: alias.name,
                signature: alias.signature,
                provisioned: alias.provisioned,
                smimeCertificateRemoteId: alias.smimeCertificateId.map(Int64.init),
                rawJSON: try jsonText(entry)
            )
        }
    }

    // MARK: - Login-scoped lists

    /// Own blocks first, then the ones shared with this login. A block of mine I shared
    /// with a group I am in comes back from both routes (recorded: block 8 in both
    /// `text-blocks.json` and `text-block-shares-all.json`); the own copy wins, because only
    /// it can be edited and `UNIQUE (loginId, remoteId)` allows one row.
    public static func textBlockRecords(own: [TextBlock], shared: [TextBlock], loginId: Int64) -> [TextBlockRecord] {
        let ownIds = Set(own.map(\.id))
        func record(_ block: TextBlock, isShared: Bool) -> TextBlockRecord {
            TextBlockRecord(
                loginId: loginId,
                remoteId: Int64(block.id),
                title: block.title ?? "",
                content: block.content ?? "",
                isShared: isShared,
                ownerId: block.owner
            )
        }
        return own.map { record($0, isShared: false) }
            + shared.filter { !ownIds.contains($0.id) }.map { record($0, isShared: true) }
    }

    public static func textBlockShareRecords(_ shares: [TextBlockShare], textBlockId: Int64) -> [TextBlockShareRecord] {
        shares.compactMap { share in
            guard let shareWith = share.shareWith, !shareWith.isEmpty else { return nil }
            return TextBlockShareRecord(
                textBlockId: textBlockId,
                remoteId: share.id.map(Int64.init),
                shareWith: shareWith,
                type: share.type ?? "user",
                displayName: share.displayName
            )
        }
    }

    /// Individual addresses and whole domains share one list; `type` tells them apart.
    public static func trustedSenderRecords(_ senders: [TrustedSender], loginId: Int64) -> [TrustedSenderRecord] {
        senders.compactMap { sender in
            guard let email = sender.email, !email.isEmpty else { return nil }
            return TrustedSenderRecord(
                loginId: loginId,
                remoteId: sender.id.map(Int64.init),
                email: email,
                type: sender.type ?? "individual"
            )
        }
    }

    public static func internalAddressRecords(_ addresses: [InternalAddress], loginId: Int64) -> [InternalAddressRecord]
    {
        addresses.compactMap { entry in
            guard let address = entry.address, !address.isEmpty else { return nil }
            return InternalAddressRecord(
                loginId: loginId,
                remoteId: entry.id.map(Int64.init),
                address: address,
                type: entry.type ?? "individual"
            )
        }
    }

    public static func smimeCertificateRecords(
        _ certificates: [SmimeCertificate],
        loginId: Int64
    ) throws -> [SmimeCertificateRecord] {
        try certificates.map { certificate in
            SmimeCertificateRecord(
                loginId: loginId,
                remoteId: Int64(certificate.id),
                emailAddress: certificate.emailAddress ?? certificate.info?.emailAddress ?? "",
                hasPrivateKey: certificate.hasKey,
                notAfter: certificate.info?.notAfter.map(Int64.init),
                canSign: certificate.info?.purposes?.sign ?? false,
                canEncrypt: certificate.info?.purposes?.encrypt ?? false,
                infoJSON: try jsonText(CertificateInfoJSON(certificate.info))
            )
        }
    }

    // MARK: - Account-scoped lists

    public static func delegationRecords(_ delegates: [AccountDelegate], accountId: Int64) -> [DelegationRecord] {
        delegates.map { delegate in
            DelegationRecord(accountId: accountId, userId: delegate.userId, displayName: delegate.displayName)
        }
    }

    public static func quickActionRecord(_ action: QuickAction, accountId: Int64) -> QuickActionRecord {
        QuickActionRecord(accountId: accountId, remoteId: Int64(action.id), name: action.name ?? "")
    }

    /// Steps in the server's `order`, which becomes `position` because `order` is an SQL
    /// keyword. A step with no order sorts last, ties by id, so a chain always runs the same
    /// way round.
    public static func quickActionStepRecords(_ action: QuickAction, quickActionId: Int64) -> [QuickActionStepRecord] {
        action.actionSteps
            .sorted { ($0.order ?? .max, $0.id) < ($1.order ?? .max, $1.id) }
            .compactMap { step in
                guard let name = step.name, !name.isEmpty else { return nil }
                return QuickActionStepRecord(
                    quickActionId: quickActionId,
                    remoteId: Int64(step.id),
                    name: name,
                    position: step.order ?? 0,
                    tagRemoteId: step.tagId.map(Int64.init),
                    mailboxRemoteId: step.mailboxId.map(Int64.init)
                )
            }
    }

    /// The Sieve row of an account with Sieve on. Each of the three parts is nil when its
    /// request failed, and the previous row's value is kept for it: one failing route does
    /// not blank what the other two, or the last refresh, got right.
    public static func sieveStateRecord(
        account: AccountRecord,
        script: SieveScript??,
        filters: [MailFilter]??,
        outOfOffice: OutOfOfficeState??,
        previous: SieveStateRecord?,
        fetchedAt: Int64
    ) throws -> SieveStateRecord {
        let fields = (try? JSONDecoder().decode(AnyJSON.self, from: Data(account.rawJSON.utf8)))?.objectValue ?? [:]
        var record = SieveStateRecord(
            accountId: account.id,
            sieveEnabled: true,
            sieveHost: fields.string("sieveHost"),
            sievePort: fields.int("sievePort"),
            sieveUser: fields.string("sieveUser"),
            sieveSslMode: fields.string("sieveSslMode"),
            script: previous?.script,
            scriptName: previous?.scriptName,
            filtersJSON: previous?.filtersJSON,
            outOfOfficeJSON: previous?.outOfOfficeJSON,
            fetchedAt: fetchedAt
        )
        if let script {
            record.script = script?.script
            record.scriptName = script?.scriptName
        }
        if let filters {
            record.filtersJSON = try filters.map { try jsonText($0.map(FilterJSON.init)) }
        }
        if let outOfOffice {
            record.outOfOfficeJSON = try outOfOffice.map { try jsonText(OutOfOfficeJSON($0)) }
        }
        return record
    }

    // MARK: - Outbox

    /// - Parameter accountId: the mirror's id for the entry's account; the caller groups
    ///   the login-wide `GET /api/outbox` by the payload's server account id.
    public static func outboxRecord(
        _ message: RawBacked<LocalMessage>,
        accountId: Int64,
        syncedAt: Int64
    ) throws -> OutboxMessageRecord {
        let value = message.value
        var recipients: [RecipientJSON] = []
        for (kind, list) in [("to", value.to), ("cc", value.cc), ("bcc", value.bcc)] {
            for address in list {
                guard let email = address.email, !email.isEmpty else { continue }
                recipients.append(RecipientJSON(kind: kind, email: email, label: address.label))
            }
        }
        return OutboxMessageRecord(
            accountId: accountId,
            remoteId: Int64(value.id),
            aliasRemoteId: value.aliasId.map(Int64.init),
            subject: value.subject,
            bodyPlain: value.bodyPlain,
            bodyHtml: value.bodyHtml,
            isHtml: value.isHtml,
            inReplyToMessageId: value.inReplyToMessageId,
            smimeSign: value.smimeSign,
            smimeEncrypt: value.smimeEncrypt,
            requestMdn: value.requestMdn,
            sendAt: value.sendAt.map(Int64.init),
            failed: value.failed,
            recipientsJSON: try jsonText(recipients),
            attachmentsJSON: try jsonText(value.attachments.map(AttachmentJSON.init)),
            syncedAt: syncedAt,
            rawJSON: try jsonText(message)
        )
    }
}

// MARK: - JSON column shapes

/// `outboxMessage.recipientsJSON`: one object per address, `kind` being to, cc or bcc —
/// the same vocabulary as `draftRecipient.kind`.
struct RecipientJSON: Encodable {
    let kind: String
    let email: String
    let label: String?
}

/// `outboxMessage.attachmentsJSON`.
struct AttachmentJSON: Encodable {
    let id: Int
    let fileName: String?
    let mimeType: String?
    let type: String?

    init(_ attachment: LocalAttachment) {
        id = attachment.id
        fileName = attachment.fileName
        mimeType = attachment.mimeType
        type = attachment.type
    }
}

/// `smimeCertificate.infoJSON`: the parsed certificate details the settings table shows.
struct CertificateInfoJSON: Encodable {
    let commonName: String?
    let emailAddress: String?
    let notAfter: Int?
    let sign: Bool
    let encrypt: Bool
    let isChainVerified: Bool

    init(_ info: SmimeCertificate.Info?) {
        commonName = info?.commonName
        emailAddress = info?.emailAddress
        notAfter = info?.notAfter
        sign = info?.purposes?.sign ?? false
        encrypt = info?.purposes?.encrypt ?? false
        isChainVerified = info?.isChainVerified ?? false
    }
}

/// `sieveState.filtersJSON`, in the server's own field names so WS-39 can send an edited
/// list straight back to `PUT /api/filter/{id}`.
struct FilterJSON: Encodable {
    struct Test: Encodable {
        let field: String?
        let `operator`: String?
        let values: [String]
    }

    let id: Int?
    let name: String?
    let enable: Bool
    let `operator`: String?
    let priority: Int?
    let tests: [Test]
    let actions: [AnyJSON]

    init(_ filter: MailFilter) {
        id = filter.id
        name = filter.name
        enable = filter.enable
        `operator` = filter.operator
        priority = filter.priority
        tests = filter.tests.map { Test(field: $0.field, operator: $0.operator, values: $0.values) }
        actions = filter.actions
    }
}

/// `sieveState.outOfOfficeJSON`, in the server's field names for the same reason.
struct OutOfOfficeJSON: Encodable {
    let enabled: Bool
    let start: String?
    let end: String?
    let subject: String?
    let message: String?

    init(_ state: OutOfOfficeState) {
        enabled = state.enabled
        start = state.start
        end = state.end
        subject = state.subject
        message = state.message
    }
}
