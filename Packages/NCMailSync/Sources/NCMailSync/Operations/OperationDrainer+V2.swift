// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

/// A DAV write the handler could not reconcile after a 412. Parked rather than dropped: the
/// row is the conflict the user resolves with **Retry now** or **Discard**.
struct DAVConflict: Error {}

/// The v2 kinds' requests, their success write-back and their reversal.
///
/// Every request is built from server ids (ADR-0033) and every negative id is a placeholder
/// resolved through `meta` (ADR-0081). A placeholder that does not resolve throws
/// `MailError.notFound`, which drops the row exactly as a vanished message does.
extension OperationDrainer {
    // MARK: - Requests

    func sendV2(_ item: CollapsedOperation) async throws -> [LocalEffect] {
        guard let intent = item.payload.intent else { throw MailError.notFound }
        switch item.kind {
        // MARK: Tags
        case .setTag, .unsetTag:
            let messageId = try messageRemoteId(item)
            let label = try await resolvedLabel(intent.imapLabel)
            if item.kind == .setTag {
                _ = try await client.put(Endpoint.addMessageTag(messageId: messageId, imapLabel: label))
            } else {
                _ = try await client.delete(Endpoint.removeMessageTag(messageId: messageId, imapLabel: label))
            }
        case .createTag:
            guard let placeholder = intent.placeholder else { throw MailError.notFound }
            let tag = try await client.post(
                Endpoint.createTag,
                body: TagRequest(displayName: intent.name ?? "", color: intent.color ?? "")
            )
            var effects: [RowEffect] = [
                .replaceTagRemoteId(
                    accountId: accountId, from: placeholder, to: Int64(tag.id), imapLabel: tag.imapLabel),
                Self.placeholderMeta("tag", placeholder, Int64(tag.id)),
            ]
            if let label = intent.imapLabel {
                effects.append(.setMeta(key: Self.labelKey(label), value: tag.imapLabel))
            }
            return [LocalEffect(messageIds: [], rows: effects)]
        case .updateTag:
            let id = try await resolved(intent.targetRemoteId, "tag")
            _ = try await client.put(
                Endpoint.updateTag(id: Int(id)),
                body: TagRequest(displayName: intent.name ?? "", color: intent.color ?? "")
            )
        case .deleteTag:
            let id = try await resolved(intent.targetRemoteId, "tag")
            _ = try await client.delete(Endpoint.deleteTag(accountId: Int(try await accountRemoteId()), tagId: Int(id)))

        // MARK: Snooze
        case .snooze:
            _ = try await client.post(
                Endpoint.snoozeMessage(id: try messageRemoteId(item)),
                body: try snoozeRequest(intent)
            )
        case .unsnooze:
            _ = try await client.post(Endpoint.unsnoozeMessage(id: try messageRemoteId(item)))
        case .snoozeThread:
            _ = try await client.post(
                Endpoint.snoozeThread(messageId: try messageRemoteId(item)),
                body: try snoozeRequest(intent)
            )
        case .unsnoozeThread:
            _ = try await client.post(Endpoint.unsnoozeThread(messageId: try messageRemoteId(item)))

        // MARK: Mailboxes
        case .createMailbox:
            guard let placeholder = intent.placeholder, let name = intent.name else { throw MailError.notFound }
            let mailbox = try await client.post(
                Endpoint.createMailbox,
                body: CreateMailboxRequest(accountId: Int(try await accountRemoteId()), name: name)
            )
            let write = try MirrorMapping.mailboxWrite(mailbox, accountId: accountId)
            return [
                LocalEffect(
                    messageIds: [],
                    rows: [
                        .replaceMailboxRemoteId(accountId: accountId, from: placeholder, to: write.remoteId),
                        .upsertMailbox(write),
                        Self.placeholderMeta("mailbox", placeholder, write.remoteId),
                    ]
                )
            ]
        case .renameMailbox, .moveMailbox:
            _ = try await client.patch(
                Endpoint.patchMailbox(id: Int(try await resolved(intent.targetRemoteId, "mailbox"))),
                body: PatchMailboxRequest(name: intent.name)
            )
        case .setMailboxSubscribed:
            _ = try await client.patch(
                Endpoint.patchMailbox(id: Int(try await resolved(intent.targetRemoteId, "mailbox"))),
                body: PatchMailboxRequest(subscribed: intent.flag)
            )
        case .setMailboxSyncInBackground:
            _ = try await client.patch(
                Endpoint.patchMailbox(id: Int(try await resolved(intent.targetRemoteId, "mailbox"))),
                body: PatchMailboxRequest(syncInBackground: intent.flag)
            )
        case .deleteMailbox:
            _ = try await client.delete(
                Endpoint.deleteMailbox(id: Int(try await resolved(intent.targetRemoteId, "mailbox"))))
        case .clearMailbox:
            _ = try await client.post(
                Endpoint.clearMailbox(id: Int(try await resolved(intent.targetRemoteId, "mailbox"))))
        case .markMailboxRead:
            _ = try await client.post(
                Endpoint.markMailboxRead(id: Int(try await resolved(intent.targetRemoteId, "mailbox"))))

        // MARK: Settings
        case .setPreference:
            guard let key = intent.key else { throw MailError.notFound }
            _ = try await client.put(
                Endpoint.setPreference(key: key),
                body: PreferenceRequest(key: key, value: .string(intent.value ?? ""))
            )
        case .patchAccount:
            let patch = intent.accountPatch ?? AccountPatch()
            let remote = intent.accountPatchRemote ?? [:]
            _ = try await client.patch(
                Endpoint.patchAccount(id: Int(try await accountRemoteId())),
                body: PatchAccountRequest(
                    editorMode: patch.editorMode,
                    order: patch.order,
                    showSubscribedOnly: patch.showSubscribedOnly,
                    draftsMailboxId: remote["draftsMailboxId"].map(Int.init),
                    sentMailboxId: remote["sentMailboxId"].map(Int.init),
                    trashMailboxId: remote["trashMailboxId"].map(Int.init),
                    archiveMailboxId: remote["archiveMailboxId"].map(Int.init),
                    snoozeMailboxId: remote["snoozeMailboxId"].map(Int.init),
                    junkMailboxId: remote["junkMailboxId"].map(Int.init),
                    signatureAboveQuote: patch.signatureAboveQuote,
                    trashRetentionDays: patch.trashRetentionDays,
                    searchBody: patch.searchBody,
                    classificationEnabled: patch.classificationEnabled,
                    imipCreate: patch.imipCreate
                )
            )
        case .setSignature:
            _ = try await client.put(
                Endpoint.setAccountSignature(accountId: Int(try await accountRemoteId())),
                body: SignatureRequest(signature: intent.text)
            )
        case .createAlias:
            guard let placeholder = intent.placeholder else { throw MailError.notFound }
            let alias = try await client.post(
                Endpoint.createAlias(accountId: Int(try await accountRemoteId())),
                body: AliasRequest(alias: intent.email ?? "", aliasName: intent.name ?? "")
            )
            return [
                LocalEffect(
                    messageIds: [],
                    rows: [
                        .replaceAliasRemoteId(accountId: accountId, from: placeholder, to: Int64(alias.id)),
                        Self.placeholderMeta("alias", placeholder, Int64(alias.id)),
                    ]
                )
            ]
        case .updateAlias:
            let id = try await resolved(intent.targetRemoteId, "alias")
            _ = try await client.put(
                Endpoint.updateAlias(accountId: Int(try await accountRemoteId()), aliasId: Int(id)),
                // The certificate rides along unchanged: the route rewrites every field it
                // has, and a missing one would unlink the alias's certificate.
                body: AliasRequest(
                    alias: intent.email ?? "",
                    aliasName: intent.name ?? "",
                    smimeCertificateId: item.payload.before.rows?.alias?.smimeCertificateRemoteId.map(Int.init)
                )
            )
        case .deleteAlias:
            let id = try await resolved(intent.targetRemoteId, "alias")
            _ = try await client.delete(
                Endpoint.deleteAlias(accountId: Int(try await accountRemoteId()), aliasId: Int(id)))
        case .setAliasSignature:
            let id = try await resolved(intent.targetRemoteId, "alias")
            _ = try await client.put(
                Endpoint.setAliasSignature(accountId: Int(try await accountRemoteId()), aliasId: Int(id)),
                body: SignatureRequest(signature: intent.text)
            )

        // MARK: Text blocks
        case .createTextBlock:
            guard let placeholder = intent.placeholder, let loginId = intent.loginId else { throw MailError.notFound }
            let block = try await client.post(
                Endpoint.createTextBlock,
                body: TextBlockRequest(title: intent.title ?? "", content: intent.content ?? "")
            )
            return [
                LocalEffect(
                    messageIds: [],
                    rows: [
                        .replaceTextBlockRemoteId(loginId: loginId, from: placeholder, to: Int64(block.data.id)),
                        Self.placeholderMeta("textBlock", placeholder, Int64(block.data.id)),
                    ]
                )
            ]
        case .updateTextBlock:
            let id = try await resolved(intent.targetRemoteId, "textBlock")
            _ = try await client.put(
                Endpoint.updateTextBlock(id: Int(id)),
                body: TextBlockRequest(title: intent.title ?? "", content: intent.content ?? "")
            )
        case .deleteTextBlock:
            _ = try await client.delete(
                Endpoint.deleteTextBlock(id: Int(try await resolved(intent.targetRemoteId, "textBlock"))))
        case .shareTextBlock:
            let id = try await resolved(intent.targetRemoteId, "textBlock")
            _ = try await client.post(
                Endpoint.shareTextBlock,
                body: TextBlockShareRequest(
                    textBlockId: Int(id), shareWith: intent.shareWith ?? "", type: intent.type ?? "user")
            )
        case .unshareTextBlock:
            let id = try await resolved(intent.targetRemoteId, "textBlock")
            _ = try await client.delete(
                Endpoint.unshareTextBlock(textBlockId: Int(id), shareWith: intent.shareWith ?? ""))

        // MARK: Quick actions
        case .createQuickAction:
            guard let placeholder = intent.placeholder else { throw MailError.notFound }
            let action = try await client.post(
                Endpoint.createQuickAction,
                body: QuickActionRequest(name: intent.name ?? "", accountId: Int(try await accountRemoteId()))
            )
            return [
                LocalEffect(
                    messageIds: [],
                    rows: [
                        .replaceQuickActionRemoteId(accountId: accountId, from: placeholder, to: Int64(action.data.id)),
                        Self.placeholderMeta("quickAction", placeholder, Int64(action.data.id)),
                    ]
                )
            ]
        case .updateQuickAction:
            let id = try await resolved(intent.targetRemoteId, "quickAction")
            _ = try await client.put(
                Endpoint.renameQuickAction(id: Int(id)),
                body: QuickActionRequest(name: intent.name ?? "", accountId: Int(try await accountRemoteId()))
            )
        case .deleteQuickAction:
            _ = try await client.delete(
                Endpoint.deleteQuickAction(id: Int(try await resolved(intent.targetRemoteId, "quickAction"))))
        case .upsertActionStep:
            let actionId = try await resolved(intent.parentRemoteId, "quickAction")
            let request = ActionStepRequest(
                name: intent.name ?? "",
                order: intent.order ?? 0,
                actionId: Int(actionId),
                tagId: try await optionalResolved(intent.tagRemoteId, "tag").map(Int.init),
                mailboxId: try await optionalResolved(intent.mailboxRemoteId, "mailbox").map(Int.init)
            )
            if let placeholder = intent.placeholder {
                let step = try await client.post(Endpoint.createActionStep, body: request)
                return [
                    LocalEffect(
                        messageIds: [],
                        rows: [
                            .replaceQuickActionStepRemoteId(
                                accountId: accountId, quickActionRemoteId: actionId, from: placeholder,
                                to: Int64(step.data.id)
                            ),
                            Self.placeholderMeta("actionStep", placeholder, Int64(step.data.id)),
                        ]
                    )
                ]
            }
            _ = try await client.put(
                Endpoint.updateActionStep(id: Int(try await resolved(intent.targetRemoteId, "actionStep"))),
                body: request
            )
        case .deleteActionStep:
            _ = try await client.delete(
                Endpoint.deleteActionStep(id: Int(try await resolved(intent.targetRemoteId, "actionStep"))))

        // MARK: Addresses
        case .addInternalAddress:
            _ = try await client.put(
                Endpoint.addInternalAddress(address: intent.email ?? "", type: intent.type ?? "individual"))
        case .removeInternalAddress:
            _ = try await client.delete(
                Endpoint.removeInternalAddress(address: intent.email ?? "", type: intent.type ?? "individual"))
        case .trustDomain:
            guard let domain = intent.email else { throw MailError.notFound }
            if intent.flag ?? true {
                _ = try await client.put(Endpoint.trustSender(email: domain, type: "domain"))
            } else {
                _ = try await client.delete(Endpoint.untrustSender(email: domain, type: "domain"))
            }

        // MARK: Mail actions
        case .sendMDN:
            _ = try await client.post(Endpoint.sendMDN(messageId: try messageRemoteId(item)))
        case .unsubscribe:
            _ = try await client.post(Endpoint.unsubscribe(messageId: try messageRemoteId(item)))
        case .saveToFiles:
            let body = TargetPathRequest(targetPath: intent.targetPath ?? "/")
            if let attachmentId = intent.attachmentId {
                _ = try await client.post(
                    Endpoint.saveAttachmentToFiles(messageId: try messageRemoteId(item), attachmentId: attachmentId),
                    body: body
                )
            } else {
                _ = try await client.post(Endpoint.saveMessageToFiles(messageId: try messageRemoteId(item)), body: body)
            }

        default:
            throw MailError.notFound
        }
        return []
    }

    /// Hands a DAV row to the contacts sync's handler and maps what it throws.
    func sendDAV(_ item: CollapsedOperation) async throws {
        guard let payload = item.payload.dav else { throw MailError.notFound }
        guard let handler = configuration.dav else {
            // Queued while a handler existed, drained without one: a wiring fault, not the
            // operation's. It retries with backoff and surfaces after five attempts.
            throw MailError.server(status: 503, message: nil)
        }
        do {
            try await handler.send(
                DAVWrite(operationId: item.id, kind: item.kind, accountId: item.accountId, payload: payload))
        } catch let error as DAVError {
            throw Self.mailError(for: error)
        }
    }

    static func mailError(for error: DAVError) -> any Error {
        switch error {
        case .unauthorized: MailError.unauthorized
        case .forbidden: MailError.forbidden
        case .notFound: MailError.notFound
        case .preconditionFailed: DAVConflict()
        case .collectionConflict(let status, let message): MailError.server(status: status, message: message)
        case .propertyUpdateFailed(let status, _): MailError.server(status: status, message: nil)
        case .server(let status, _, let message): MailError.server(status: status, message: message)
        case .transport(let underlying): MailError.transport(underlying)
        case .invalidResponse: MailError.server(status: 502, message: nil)
        }
    }

    /// Keeps a conflicted DAV row: visible at once, never retried on its own. `retryAll`
    /// clears the wait and the marker; `discard` reverts through the handler.
    func park(_ item: CollapsedOperation) async {
        // Ten years: "until the user says so", in a column that has to hold a time.
        let parkedUntil = configuration.now() + 10 * 365 * 24 * 3600
        try? await store.reschedule(
            ids: item.absorbedIds,
            attempts: max(item.attempts, configuration.visibleAfterAttempts),
            nextAttemptAt: parkedUntil,
            lastError: DAVWrite.conflictMarker
        )
        OperationLog.queue.error(
            "operation \(item.id, privacy: .public) \(item.kind.rawValue, privacy: .public) parked: conflict")
    }

    /// **Discard** for a DAV row: the handler owns the contact rows, so it puts them back.
    func revertDAV(_ item: CollapsedOperation) async {
        guard item.kind.isDAV, let handler = configuration.dav, let payload = item.payload.dav else { return }
        await handler.revert(
            DAVWrite(operationId: item.id, kind: item.kind, accountId: item.accountId, payload: payload))
    }

    // MARK: - Reversal

    /// The row effects that put a v2 kind's settings rows back to `before.rows`.
    func rowReversal(of item: CollapsedOperation) -> [RowEffect] {
        guard let before = item.payload.before.rows, let intent = item.payload.intent else { return [] }
        let account = item.accountId
        switch item.kind {
        case .setTag, .unsetTag:
            guard let label = intent.imapLabel, let tags = before.messageTags else { return [] }
            return tags.keys.sorted().map { messageId in
                .setMessageTag(
                    messageIds: [messageId], accountId: account, imapLabel: label,
                    present: tags[messageId]?.contains(label) ?? false
                )
            }
        case .createTag:
            return intent.placeholder.map { [.deleteTag(accountId: account, remoteId: $0)] } ?? []
        case .updateTag, .deleteTag:
            return before.tag.map {
                [
                    .upsertTag(
                        accountId: account, remoteId: $0.remoteId, imapLabel: $0.imapLabel, displayName: $0.displayName,
                        color: $0.color)
                ]
            } ?? []
        case .snooze, .unsnooze, .snoozeThread, .unsnoozeThread:
            let until = before.snoozeUntil ?? [:]
            return item.payload.before.messageIds.map { .setSnooze(messageIds: [$0], until: until[$0]) }
        case .createMailbox:
            return intent.placeholder.map { [.deleteMailbox(accountId: account, remoteId: $0)] } ?? []
        case .renameMailbox, .moveMailbox, .deleteMailbox, .setMailboxSubscribed, .setMailboxSyncInBackground:
            return before.mailbox.map { [.upsertMailbox(MailboxWrite(record: $0))] } ?? []
        case .setPreference:
            guard let loginId = intent.loginId, let key = before.preferenceKey else { return [] }
            return [
                .setPreference(
                    loginId: loginId, key: key, value: before.preferenceValue, fetchedAt: configuration.now())
            ]
        case .patchAccount, .setSignature:
            return before.account.map { [.upsertAccount(AccountWrite(record: $0))] } ?? []
        case .createAlias:
            return intent.placeholder.map { [.deleteAlias(accountId: account, remoteId: $0)] } ?? []
        case .updateAlias, .deleteAlias, .setAliasSignature:
            return before.alias.map { [.upsertAlias($0)] } ?? []
        case .createTextBlock:
            guard let loginId = intent.loginId, let placeholder = intent.placeholder else { return [] }
            return [.deleteTextBlock(loginId: loginId, remoteId: placeholder)]
        case .updateTextBlock, .deleteTextBlock:
            return before.textBlock.map { [.upsertTextBlock($0)] } ?? []
        case .shareTextBlock, .unshareTextBlock:
            guard let loginId = intent.loginId, let block = intent.targetRemoteId, let shareWith = intent.shareWith
            else { return [] }
            return [
                .setTextBlockShare(
                    loginId: loginId, textBlockRemoteId: block, shareWith: shareWith, type: intent.type ?? "user",
                    displayName: before.shareDisplayName, present: before.present ?? false
                )
            ]
        case .createQuickAction:
            return intent.placeholder.map { [.deleteQuickAction(accountId: account, remoteId: $0)] } ?? []
        case .updateQuickAction, .deleteQuickAction:
            return before.quickAction.map { [.upsertQuickAction($0)] } ?? []
        case .upsertActionStep, .deleteActionStep:
            guard let parent = intent.parentRemoteId else { return [] }
            if let step = before.quickActionStep {
                return [.upsertQuickActionStep(accountId: account, quickActionRemoteId: parent, step: step)]
            }
            guard let placeholder = intent.placeholder else { return [] }
            return [.deleteQuickActionStep(accountId: account, quickActionRemoteId: parent, stepRemoteId: placeholder)]
        case .addInternalAddress, .removeInternalAddress:
            guard let loginId = intent.loginId, let address = intent.email else { return [] }
            return [
                .setInternalAddress(
                    loginId: loginId, address: address, type: intent.type ?? "individual",
                    present: before.present ?? false)
            ]
        case .trustDomain:
            guard let loginId = intent.loginId, let domain = intent.email else { return [] }
            return [
                .setTrustedSender(loginId: loginId, email: domain, type: "domain", present: before.present ?? false)
            ]
        default:
            return []
        }
    }

    // MARK: - Ids

    private func messageRemoteId(_ item: CollapsedOperation) throws -> Int {
        guard let remoteId = item.payload.remoteId else { throw MailError.notFound }
        return Int(remoteId)
    }

    private func accountRemoteId() async throws -> Int64 {
        guard let account = try await store.account(id: accountId) else { throw MailError.notFound }
        return account.remoteId
    }

    private func snoozeRequest(_ intent: OperationIntent) throws -> SnoozeRequest {
        guard let until = intent.until, let destination = intent.mailboxRemoteId else { throw MailError.notFound }
        return SnoozeRequest(unixTimestamp: Int(until), destMailboxId: Int(destination))
    }

    /// A server id, through the placeholder map when it is negative (ADR-0081).
    private func resolved(_ id: Int64?, _ family: String) async throws -> Int64 {
        guard let id else { throw MailError.notFound }
        guard id < 0 else { return id }
        guard
            let text = try await store.metaValue(forKey: Self.placeholderKey(family, id)),
            let real = Int64(text)
        else { throw MailError.notFound }
        return real
    }

    private func optionalResolved(_ id: Int64?, _ family: String) async throws -> Int64? {
        guard let id else { return nil }
        return try await resolved(id, family)
    }

    /// An offline-created tag's label, swapped for the server's once the create drained.
    private func resolvedLabel(_ label: String?) async throws -> String {
        guard let label else { throw MailError.notFound }
        guard label.hasPrefix(MutationQueue.placeholderLabelPrefix) else { return label }
        guard let real = try await store.metaValue(forKey: Self.labelKey(label)) else { throw MailError.notFound }
        return real
    }

    static func placeholderKey(_ family: String, _ placeholder: Int64) -> String {
        "queue.placeholder.\(family).\(placeholder)"
    }

    static func labelKey(_ label: String) -> String {
        "queue.placeholder.tagLabel.\(label)"
    }

    static func placeholderMeta(_ family: String, _ placeholder: Int64, _ real: Int64) -> RowEffect {
        .setMeta(key: placeholderKey(family, placeholder), value: String(real))
    }
}
