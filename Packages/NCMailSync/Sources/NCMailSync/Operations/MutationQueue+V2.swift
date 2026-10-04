// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailStore

/// The v2 kinds' rows: intent, `before`, and the optimistic local change.
///
/// Every local change here is a `LocalEffect` — message columns, or `RowEffect`s for the
/// settings tables — so `MailStore.enqueue(_:applying:)` writes it in the same transaction as
/// the queue row (ADR-0005). The DAV kinds are the exception: their local change is the
/// contacts sync's own write, applied by `perform` right after.
///
/// Settings rows are named by server id, and a create gets a negative placeholder that the
/// drain later swaps for the server's (ADR-0081).
extension MutationQueue {
    func v2Units(for operation: MailOperation, accountId: Int64) async throws -> [Unit] {
        switch operation {
        // MARK: Tags
        case .setTag(let messageIds, let label), .unsetTag(let messageIds, let label):
            let present: Bool = if case .setTag = operation { true } else { false }
            let labels = try await store.messageTagLabels(messageIds: messageIds)
            return try await messageUnits(messageIds, accountId: accountId) { message in
                var payload = OperationPayload(intent: OperationIntent(imapLabel: label))
                payload.before = OperationSnapshot(
                    messageIds: [message.id],
                    rows: RowSnapshot(messageTags: [message.id: labels[message.id] ?? []])
                )
                return Unit(
                    record: self.record(
                        kind: present ? .setTag : .unsetTag, accountId: accountId, message: message, payload: payload
                    ),
                    effect: LocalEffect(
                        messageIds: [],
                        rows: [
                            .setMessageTag(
                                messageIds: [message.id], accountId: accountId, imapLabel: label, present: present)
                        ]
                    )
                )
            }

        case .createTag(let displayName, let color):
            let placeholder = Self.placeholder()
            let label = Self.placeholderLabel(placeholder)
            return [
                settingUnit(
                    .createTag, accountId: accountId,
                    intent: OperationIntent(
                        placeholder: placeholder, imapLabel: label, name: displayName, color: color),
                    before: RowSnapshot(existed: false),
                    rows: [
                        .upsertTag(
                            accountId: accountId, remoteId: placeholder, imapLabel: label, displayName: displayName,
                            color: color)
                    ]
                )
            ]

        case .updateTag(let tagRemoteId, let displayName, let color):
            let tag = try await store.tags(accountId: accountId).first { $0.remoteId == tagRemoteId }
            return [
                settingUnit(
                    .updateTag, accountId: accountId,
                    intent: OperationIntent(targetRemoteId: tagRemoteId, name: displayName, color: color),
                    before: RowSnapshot(existed: tag != nil, tag: tag),
                    rows: tag.map {
                        [
                            .upsertTag(
                                accountId: accountId, remoteId: tagRemoteId, imapLabel: $0.imapLabel,
                                displayName: displayName, color: color)
                        ]
                    } ?? []
                )
            ]

        case .deleteTag(let tagRemoteId):
            let tag = try await store.tags(accountId: accountId).first { $0.remoteId == tagRemoteId }
            return [
                settingUnit(
                    .deleteTag, accountId: accountId,
                    intent: OperationIntent(targetRemoteId: tagRemoteId),
                    before: RowSnapshot(existed: tag != nil, tag: tag),
                    rows: [.deleteTag(accountId: accountId, remoteId: tagRemoteId)]
                )
            ]

        // MARK: Snooze
        case .snooze(let messageIds, let until):
            let destination = try await snoozeMailbox(accountId: accountId)
            var units: [Unit] = []
            for messageId in messageIds {
                guard let message = try await store.message(id: messageId), message.accountId == accountId else {
                    continue
                }
                let previous = try await store.snoozeUntil(messageId: messageId)
                var payload = OperationPayload(
                    destinationMailboxId: destination.id,
                    intent: OperationIntent(
                        mailboxId: destination.id, until: until, mailboxRemoteId: destination.remoteId)
                )
                payload.before = OperationSnapshot(
                    messageIds: [message.id],
                    mailboxIds: [message.id: message.mailboxId],
                    rows: RowSnapshot(snoozeUntil: previous.map { [message.id: $0] } ?? [:])
                )
                var row = record(kind: .snooze, accountId: accountId, message: message, payload: payload)
                row.mailboxId = destination.id
                units.append(
                    Unit(
                        record: row,
                        effect: LocalEffect(
                            messageIds: [message.id],
                            mailboxId: destination.id,
                            rows: [.setSnooze(messageIds: [message.id], until: until)]
                        )
                    )
                )
            }
            return units

        case .unsnooze(let messageIds):
            var units: [Unit] = []
            for messageId in messageIds {
                guard let message = try await store.message(id: messageId), message.accountId == accountId else {
                    continue
                }
                let previous = try await store.snoozeUntil(messageId: messageId)
                var payload = OperationPayload(intent: OperationIntent())
                payload.before = OperationSnapshot(
                    messageIds: [message.id],
                    rows: RowSnapshot(snoozeUntil: previous.map { [message.id: $0] } ?? [:])
                )
                units.append(
                    Unit(
                        record: record(kind: .unsnooze, accountId: accountId, message: message, payload: payload),
                        effect: LocalEffect(messageIds: [], rows: [.setSnooze(messageIds: [message.id], until: nil)])
                    )
                )
            }
            return units

        case .snoozeThread(let rootId, let until):
            let destination = try await snoozeMailbox(accountId: accountId)
            return try await snoozeThreadUnit(
                rootId: rootId, accountId: accountId, until: until, destination: destination)

        case .unsnoozeThread(let rootId):
            return try await snoozeThreadUnit(rootId: rootId, accountId: accountId, until: nil, destination: nil)

        // MARK: Mailboxes
        case .createMailbox(let name):
            let placeholder = Self.placeholder()
            let delimiter = try await store.mailboxes(accountId: accountId).compactMap(\.delimiter).first
            let write = MailboxWrite(
                accountId: accountId,
                remoteId: placeholder,
                name: name,
                delimiter: delimiter,
                displayName: Self.leaf(of: name, delimiter: delimiter),
                isSubscribed: true
            )
            return [
                settingUnit(
                    .createMailbox, accountId: accountId,
                    intent: OperationIntent(placeholder: placeholder, name: name),
                    before: RowSnapshot(existed: false),
                    rows: [.upsertMailbox(write)]
                )
            ]

        case .renameMailbox(let mailboxId, let name):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            return [
                mailboxUnit(.renameMailbox, mailbox, intent: OperationIntent(name: name)) { write in
                    write.name = name
                    write.displayName = Self.leaf(of: name, delimiter: mailbox.delimiter)
                }
            ]

        case .moveMailbox(let mailboxId, let parentMailboxId):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            let leaf = Self.leaf(of: mailbox.name, delimiter: mailbox.delimiter)
            var name = leaf
            if let parentMailboxId {
                let parent = try await mailboxRecord(parentMailboxId, accountId: accountId)
                name = parent.name + (mailbox.delimiter ?? parent.delimiter ?? "/") + leaf
            }
            return [
                mailboxUnit(.moveMailbox, mailbox, intent: OperationIntent(name: name)) { write in
                    write.name = name
                }
            ]

        case .deleteMailbox(let mailboxId):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            var unit = mailboxUnit(.deleteMailbox, mailbox, intent: OperationIntent()) { _ in }
            unit.effect = LocalEffect(
                messageIds: [], rows: [.deleteMailbox(accountId: accountId, remoteId: mailbox.remoteId)])
            return [unit]

        case .setMailboxSubscribed(let mailboxId, let subscribed):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            return [
                mailboxUnit(.setMailboxSubscribed, mailbox, intent: OperationIntent(flag: subscribed)) { write in
                    write.isSubscribed = subscribed
                }
            ]

        case .setMailboxSyncInBackground(let mailboxId, let enabled):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            return [
                mailboxUnit(.setMailboxSyncInBackground, mailbox, intent: OperationIntent(flag: enabled)) { write in
                    write.syncInBackground = enabled
                }
            ]

        case .clearMailbox(let mailboxId):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            let ids = try await store.messageIds(mailboxId: mailboxId)
            var unit = mailboxUnit(.clearMailbox, mailbox, intent: OperationIntent()) { _ in }
            // Erased, like a delete in trash: nothing for Discard to put back, and the next
            // sync returns whatever the server still has.
            var payload = OperationPayload.decode(unit.record.payloadJSON)
            payload.erases = true
            payload.before.rows = nil
            unit.record.payloadJSON = (try? payload.encoded()) ?? "{}"
            unit.effect = LocalEffect(messageIds: ids, removesRows: true)
            return [unit]

        case .markMailboxRead(let mailboxId):
            let mailbox = try await mailboxRecord(mailboxId, accountId: accountId)
            let ids = try await store.unreadMessageIds(mailboxId: mailboxId)
            var unit = mailboxUnit(.markMailboxRead, mailbox, intent: OperationIntent()) { _ in }
            var payload = OperationPayload.decode(unit.record.payloadJSON)
            payload.before = OperationSnapshot(messageIds: ids, flags: ["seen": false])
            unit.record.payloadJSON = (try? payload.encoded()) ?? "{}"
            unit.effect = LocalEffect(messageIds: ids, flags: ["seen": true])
            return [unit]

        // MARK: Settings
        case .setPreference(let key, let value):
            let loginId = try await loginId(accountId: accountId)
            let previous = try await store.preferenceValue(key: key, loginId: loginId)
            return [
                settingUnit(
                    .setPreference, accountId: accountId,
                    intent: OperationIntent(loginId: loginId, key: key, value: value),
                    before: RowSnapshot(preferenceKey: key, preferenceValue: previous),
                    rows: [.setPreference(loginId: loginId, key: key, value: value, fetchedAt: configuration.now())]
                )
            ]

        case .patchAccount(let patch):
            let account = try await accountRecord(accountId)
            var remote: [String: Int64] = [:]
            for (field, localId) in Self.specialMailboxFields(of: patch) {
                guard let mailbox = try await store.mailbox(id: localId), mailbox.accountId == accountId else {
                    throw OperationError.noSuchMailbox
                }
                remote[field] = mailbox.remoteId
            }
            var write = AccountWrite(record: account)
            write.apply(patch, remoteMailboxIds: remote)
            return [
                settingUnit(
                    .patchAccount, accountId: accountId,
                    intent: OperationIntent(accountPatch: patch, accountPatchRemote: remote),
                    before: RowSnapshot(account: account),
                    rows: [.upsertAccount(write)]
                )
            ]

        case .setSignature(let signature):
            let account = try await accountRecord(accountId)
            var write = AccountWrite(record: account)
            write.signature = signature
            return [
                settingUnit(
                    .setSignature, accountId: accountId,
                    intent: OperationIntent(text: signature),
                    before: RowSnapshot(account: account),
                    rows: [.upsertAccount(write)]
                )
            ]

        case .createAlias(let email, let name):
            let placeholder = Self.placeholder()
            return [
                settingUnit(
                    .createAlias, accountId: accountId,
                    intent: OperationIntent(placeholder: placeholder, name: name, email: email),
                    before: RowSnapshot(existed: false),
                    rows: [
                        .upsertAlias(AliasRecord(accountId: accountId, remoteId: placeholder, email: email, name: name))
                    ]
                )
            ]

        case .updateAlias(let aliasRemoteId, let email, let name):
            let alias = try await store.alias(accountId: accountId, remoteId: aliasRemoteId)
            return [
                aliasUnit(
                    .updateAlias, accountId: accountId, remoteId: aliasRemoteId, alias: alias,
                    intent: OperationIntent(targetRemoteId: aliasRemoteId, name: name, email: email)
                ) { row in
                    row.email = email
                    row.name = name
                }
            ]

        case .deleteAlias(let aliasRemoteId):
            let alias = try await store.alias(accountId: accountId, remoteId: aliasRemoteId)
            return [
                settingUnit(
                    .deleteAlias, accountId: accountId,
                    intent: OperationIntent(targetRemoteId: aliasRemoteId),
                    before: RowSnapshot(existed: alias != nil, alias: alias),
                    rows: [.deleteAlias(accountId: accountId, remoteId: aliasRemoteId)]
                )
            ]

        case .setAliasSignature(let aliasRemoteId, let signature):
            let alias = try await store.alias(accountId: accountId, remoteId: aliasRemoteId)
            return [
                aliasUnit(
                    .setAliasSignature, accountId: accountId, remoteId: aliasRemoteId, alias: alias,
                    intent: OperationIntent(targetRemoteId: aliasRemoteId, text: signature)
                ) { row in
                    row.signature = signature
                }
            ]

        // MARK: Text blocks
        case .createTextBlock(let title, let content):
            let loginId = try await loginId(accountId: accountId)
            let placeholder = Self.placeholder()
            return [
                settingUnit(
                    .createTextBlock, accountId: accountId,
                    intent: OperationIntent(loginId: loginId, placeholder: placeholder, title: title, content: content),
                    before: RowSnapshot(existed: false),
                    rows: [
                        .upsertTextBlock(
                            TextBlockRecord(loginId: loginId, remoteId: placeholder, title: title, content: content))
                    ]
                )
            ]

        case .updateTextBlock(let remoteId, let title, let content):
            let loginId = try await loginId(accountId: accountId)
            let block = try await store.textBlock(loginId: loginId, remoteId: remoteId)
            var rows: [RowEffect] = []
            if var updated = block {
                updated.title = title
                updated.content = content
                rows = [.upsertTextBlock(updated)]
            }
            return [
                settingUnit(
                    .updateTextBlock, accountId: accountId,
                    intent: OperationIntent(loginId: loginId, targetRemoteId: remoteId, title: title, content: content),
                    before: RowSnapshot(existed: block != nil, textBlock: block),
                    rows: rows
                )
            ]

        case .deleteTextBlock(let remoteId):
            let loginId = try await loginId(accountId: accountId)
            let block = try await store.textBlock(loginId: loginId, remoteId: remoteId)
            return [
                settingUnit(
                    .deleteTextBlock, accountId: accountId,
                    intent: OperationIntent(loginId: loginId, targetRemoteId: remoteId),
                    before: RowSnapshot(existed: block != nil, textBlock: block),
                    rows: [.deleteTextBlock(loginId: loginId, remoteId: remoteId)]
                )
            ]

        case .shareTextBlock(let remoteId, let shareWith, let type):
            return [
                try await shareUnit(
                    .shareTextBlock, accountId: accountId, remoteId: remoteId, shareWith: shareWith, type: type)
            ]

        case .unshareTextBlock(let remoteId, let shareWith):
            return [
                try await shareUnit(
                    .unshareTextBlock, accountId: accountId, remoteId: remoteId, shareWith: shareWith, type: nil)
            ]

        // MARK: Quick actions
        case .createQuickAction(let name):
            let placeholder = Self.placeholder()
            return [
                settingUnit(
                    .createQuickAction, accountId: accountId,
                    intent: OperationIntent(placeholder: placeholder, name: name),
                    before: RowSnapshot(existed: false),
                    rows: [
                        .upsertQuickAction(QuickActionRecord(accountId: accountId, remoteId: placeholder, name: name))
                    ]
                )
            ]

        case .updateQuickAction(let remoteId, let name):
            let action = try await store.quickAction(accountId: accountId, remoteId: remoteId)
            var rows: [RowEffect] = []
            if var updated = action {
                updated.name = name
                rows = [.upsertQuickAction(updated)]
            }
            return [
                settingUnit(
                    .updateQuickAction, accountId: accountId,
                    intent: OperationIntent(targetRemoteId: remoteId, name: name),
                    before: RowSnapshot(existed: action != nil, quickAction: action),
                    rows: rows
                )
            ]

        case .deleteQuickAction(let remoteId):
            let action = try await store.quickAction(accountId: accountId, remoteId: remoteId)
            return [
                settingUnit(
                    .deleteQuickAction, accountId: accountId,
                    intent: OperationIntent(targetRemoteId: remoteId),
                    before: RowSnapshot(existed: action != nil, quickAction: action),
                    rows: [.deleteQuickAction(accountId: accountId, remoteId: remoteId)]
                )
            ]

        case .upsertActionStep(let step):
            let existing = try await actionStep(
                accountId: accountId, quickActionRemoteId: step.quickActionRemoteId, stepRemoteId: step.stepRemoteId)
            let stepRemoteId = step.stepRemoteId ?? Self.placeholder()
            let row = QuickActionStepRecord(
                quickActionId: 0,
                remoteId: stepRemoteId,
                name: step.name,
                position: step.order,
                tagRemoteId: step.tagRemoteId,
                mailboxRemoteId: step.mailboxRemoteId
            )
            return [
                settingUnit(
                    .upsertActionStep, accountId: accountId,
                    intent: OperationIntent(
                        targetRemoteId: step.stepRemoteId,
                        placeholder: step.stepRemoteId == nil ? stepRemoteId : nil,
                        parentRemoteId: step.quickActionRemoteId,
                        name: step.name,
                        order: step.order,
                        tagRemoteId: step.tagRemoteId,
                        mailboxRemoteId: step.mailboxRemoteId
                    ),
                    before: RowSnapshot(existed: existing != nil, quickActionStep: existing),
                    rows: [
                        .upsertQuickActionStep(
                            accountId: accountId, quickActionRemoteId: step.quickActionRemoteId, step: row)
                    ]
                )
            ]

        case .deleteActionStep(let quickActionRemoteId, let stepRemoteId):
            let existing = try await actionStep(
                accountId: accountId, quickActionRemoteId: quickActionRemoteId, stepRemoteId: stepRemoteId)
            return [
                settingUnit(
                    .deleteActionStep, accountId: accountId,
                    intent: OperationIntent(targetRemoteId: stepRemoteId, parentRemoteId: quickActionRemoteId),
                    before: RowSnapshot(existed: existing != nil, quickActionStep: existing),
                    rows: [
                        .deleteQuickActionStep(
                            accountId: accountId, quickActionRemoteId: quickActionRemoteId, stepRemoteId: stepRemoteId)
                    ]
                )
            ]

        // MARK: Addresses
        case .addInternalAddress(let address, let type), .removeInternalAddress(let address, let type):
            let add: Bool = if case .addInternalAddress = operation { true } else { false }
            let loginId = try await loginId(accountId: accountId)
            let present = try await store.internalAddresses(loginId: loginId).contains {
                $0.type == type && $0.address.caseInsensitiveCompare(address) == .orderedSame
            }
            return [
                settingUnit(
                    add ? .addInternalAddress : .removeInternalAddress, accountId: accountId,
                    intent: OperationIntent(loginId: loginId, email: address, type: type),
                    before: RowSnapshot(present: present),
                    rows: [.setInternalAddress(loginId: loginId, address: address, type: type, present: add)]
                )
            ]

        case .trustDomain(let domain, let trusted):
            let loginId = try await loginId(accountId: accountId)
            let present = try await store.trustedSenders(loginId: loginId).contains {
                $0.type == "domain" && $0.email.caseInsensitiveCompare(domain) == .orderedSame
            }
            return [
                settingUnit(
                    .trustDomain, accountId: accountId,
                    intent: OperationIntent(loginId: loginId, email: domain, flag: trusted),
                    before: RowSnapshot(present: present),
                    rows: [.setTrustedSender(loginId: loginId, email: domain, type: "domain", present: trusted)]
                )
            ]

        // MARK: Mail actions
        case .sendMDN(let messageId):
            return try await messageUnits([messageId], accountId: accountId) { message in
                var payload = OperationPayload(intent: OperationIntent())
                payload.before = OperationSnapshot(messageIds: [message.id], flags: ["mdnsent": message.isMdnSent])
                return Unit(
                    record: self.record(kind: .sendMDN, accountId: accountId, message: message, payload: payload),
                    effect: LocalEffect(messageIds: [message.id], flags: ["mdnsent": true])
                )
            }

        case .unsubscribe(let messageId):
            return try await messageUnits([messageId], accountId: accountId) { message in
                Unit(
                    record: self.record(
                        kind: .unsubscribe, accountId: accountId, message: message,
                        payload: OperationPayload(intent: OperationIntent())
                    ),
                    effect: LocalEffect(messageIds: [])
                )
            }

        case .saveToFiles(let messageId, let attachmentId, let targetPath):
            return try await messageUnits([messageId], accountId: accountId) { message in
                Unit(
                    record: self.record(
                        kind: .saveToFiles, accountId: accountId, message: message,
                        payload: OperationPayload(
                            intent: OperationIntent(attachmentId: attachmentId, targetPath: targetPath))
                    ),
                    effect: LocalEffect(messageIds: [])
                )
            }

        // MARK: Contacts and calendars
        case .contactPut(let payload): return [davUnit(.contactPut, payload, accountId: accountId)]
        case .contactDelete(let payload): return [davUnit(.contactDelete, payload, accountId: accountId)]
        case .addressBookCreate(let payload): return [davUnit(.addressBookCreate, payload, accountId: accountId)]
        case .addressBookUpdate(let payload): return [davUnit(.addressBookUpdate, payload, accountId: accountId)]
        case .addressBookDelete(let payload): return [davUnit(.addressBookDelete, payload, accountId: accountId)]
        case .addressBookShare(let payload): return [davUnit(.addressBookShare, payload, accountId: accountId)]
        case .calendarPut(let payload): return [davUnit(.calendarPut, payload, accountId: accountId)]

        case .setFlags, .move, .delete, .junk, .moveThread, .deleteThread, .trustSender:
            // v1 kinds are built by `units(for:accountId:)` and never reach here.
            return []
        }
    }

    // MARK: - Builders

    /// A row that names no message: a settings, tag or mailbox kind.
    private func settingUnit(
        _ kind: OperationKind,
        accountId: Int64,
        intent: OperationIntent,
        before: RowSnapshot,
        rows: [RowEffect]
    ) -> Unit {
        var payload = OperationPayload(intent: intent)
        payload.before.rows = before
        let now = configuration.now()
        return Unit(
            record: PendingOperationRecord(
                kind: kind.rawValue,
                accountId: accountId,
                payloadJSON: (try? payload.encoded()) ?? "{}",
                createdAt: now,
                baseSyncedAt: now
            ),
            effect: LocalEffect(messageIds: [], rows: rows)
        )
    }

    private func mailboxUnit(
        _ kind: OperationKind,
        _ mailbox: MailboxRecord,
        intent: OperationIntent,
        _ change: (inout MailboxWrite) -> Void
    ) -> Unit {
        var intent = intent
        intent.mailboxId = mailbox.id
        intent.targetRemoteId = mailbox.remoteId
        var write = MailboxWrite(record: mailbox)
        change(&write)
        var unit = settingUnit(
            kind, accountId: mailbox.accountId,
            intent: intent,
            before: RowSnapshot(mailbox: mailbox),
            rows: [.upsertMailbox(write)]
        )
        unit.record.mailboxId = mailbox.id
        return unit
    }

    private func aliasUnit(
        _ kind: OperationKind,
        accountId: Int64,
        remoteId: Int64,
        alias: AliasRecord?,
        intent: OperationIntent,
        _ change: (inout AliasRecord) -> Void
    ) -> Unit {
        var rows: [RowEffect] = []
        if var updated = alias {
            change(&updated)
            rows = [.upsertAlias(updated)]
        }
        return settingUnit(
            kind, accountId: accountId, intent: intent, before: RowSnapshot(existed: alias != nil, alias: alias),
            rows: rows)
    }

    private func shareUnit(
        _ kind: OperationKind,
        accountId: Int64,
        remoteId: Int64,
        shareWith: String,
        type: String?
    ) async throws -> Unit {
        let loginId = try await loginId(accountId: accountId)
        var existing: TextBlockShareRecord?
        if let block = try await store.textBlock(loginId: loginId, remoteId: remoteId), let blockId = block.id {
            existing = try await store.textBlockShares(textBlockId: blockId).first { $0.shareWith == shareWith }
        }
        let shareType = type ?? existing?.type ?? "user"
        let present = kind == .shareTextBlock
        return settingUnit(
            kind, accountId: accountId,
            intent: OperationIntent(loginId: loginId, targetRemoteId: remoteId, type: shareType, shareWith: shareWith),
            before: RowSnapshot(present: existing != nil, shareDisplayName: existing?.displayName),
            rows: [
                .setTextBlockShare(
                    loginId: loginId, textBlockRemoteId: remoteId, shareWith: shareWith, type: shareType,
                    displayName: existing?.displayName, present: present
                )
            ]
        )
    }

    private func davUnit(_ kind: OperationKind, _ dav: DAVWritePayload, accountId: Int64) -> Unit {
        let now = configuration.now()
        return Unit(
            record: PendingOperationRecord(
                kind: kind.rawValue,
                accountId: accountId,
                payloadJSON: (try? OperationPayload(dav: dav).encoded()) ?? "{}",
                createdAt: now,
                baseSyncedAt: now
            ),
            // The handler applies the contact/calendar change; there is no message effect.
            effect: LocalEffect(messageIds: []),
            dav: dav
        )
    }

    private func snoozeThreadUnit(
        rootId: String,
        accountId: Int64,
        until: Int64?,
        destination: MailboxRecord?
    ) async throws -> [Unit] {
        let members = try await store.threadMessages(accountId: accountId, rootId: rootId)
        guard let anchor = members.first else { return [] }
        var snoozed: [Int64: Int64] = [:]
        for member in members {
            if let value = try await store.snoozeUntil(messageId: member.id) { snoozed[member.id] = value }
        }
        let ids = members.map(\.id)
        var payload = OperationPayload(
            destinationMailboxId: destination?.id,
            intent: OperationIntent(mailboxId: destination?.id, until: until, mailboxRemoteId: destination?.remoteId)
        )
        payload.before = OperationSnapshot(
            messageIds: ids,
            mailboxIds: destination == nil
                ? [:] : Dictionary(members.map { ($0.id, $0.mailboxId) }, uniquingKeysWith: { first, _ in first }),
            rows: RowSnapshot(snoozeUntil: snoozed)
        )
        var row = record(
            kind: until == nil ? .unsnoozeThread : .snoozeThread, accountId: accountId, message: anchor,
            payload: payload)
        row.threadRootId = rootId
        row.mailboxId = destination?.id
        row.baseSyncedAt = members.map(\.syncedAt).min() ?? anchor.syncedAt
        return [
            Unit(
                record: row,
                effect: LocalEffect(
                    messageIds: destination == nil ? [] : ids,
                    mailboxId: destination?.id,
                    rows: [.setSnooze(messageIds: ids, until: until)]
                )
            )
        ]
    }

    // MARK: - Lookups

    private func accountRecord(_ accountId: Int64) async throws -> AccountRecord {
        guard let account = try await store.account(id: accountId) else {
            throw OperationError.accountNotMirrored(accountId: accountId)
        }
        return account
    }

    private func mailboxRecord(_ mailboxId: Int64, accountId: Int64) async throws -> MailboxRecord {
        guard let mailbox = try await store.mailbox(id: mailboxId), mailbox.accountId == accountId else {
            throw OperationError.noSuchMailbox
        }
        return mailbox
    }

    /// The account's snooze mailbox, local row. `account.snoozeMailboxId` is the server's
    /// number, like its siblings (see ``localMailboxId(for:accountId:)``).
    private func snoozeMailbox(accountId: Int64) async throws -> MailboxRecord {
        let account = try await accountRecord(accountId)
        guard
            let remoteId = account.snoozeMailboxId,
            let mailbox = try await store.mailboxes(accountId: accountId).first(where: { $0.remoteId == remoteId })
        else { throw OperationError.noSnoozeMailbox }
        return mailbox
    }

    /// The login an account belongs to, created if the mirror has not met it yet.
    func loginId(accountId: Int64) async throws -> Int64 {
        let account = try await accountRecord(accountId)
        var login = try await store.login(for: account.identity)
        if login == nil { login = try await store.ensureLogin(account.identity) }
        guard let id = login?.id else { throw OperationError.accountNotMirrored(accountId: accountId) }
        return id
    }

    private func actionStep(
        accountId: Int64, quickActionRemoteId: Int64, stepRemoteId: Int64?
    ) async throws -> QuickActionStepRecord? {
        guard
            let stepRemoteId,
            let action = try await store.quickAction(accountId: accountId, remoteId: quickActionRemoteId),
            let actionId = action.id
        else { return nil }
        return try await store.quickActionSteps(quickActionId: actionId).first { $0.remoteId == stepRemoteId }
    }

    // MARK: - Placeholders (ADR-0081)

    /// A negative server id for a row created offline. Random rather than counted, so two
    /// creates in one second, or across a relaunch, cannot collide; negative, so no real id
    /// ever can.
    static func placeholder() -> Int64 {
        -Int64.random(in: 1...(Int64.max / 2))
    }

    /// The IMAP keyword an offline-created tag carries until the server names it.
    static func placeholderLabel(_ placeholder: Int64) -> String {
        "\(placeholderLabelPrefix)\(-placeholder)"
    }

    static let placeholderLabelPrefix = "$ncmail_pending"

    static func leaf(of name: String, delimiter: String?) -> String {
        guard let delimiter, !delimiter.isEmpty else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }

    static func specialMailboxFields(of patch: AccountPatch) -> [(String, Int64)] {
        [
            ("draftsMailboxId", patch.draftsMailboxId),
            ("sentMailboxId", patch.sentMailboxId),
            ("trashMailboxId", patch.trashMailboxId),
            ("archiveMailboxId", patch.archiveMailboxId),
            ("snoozeMailboxId", patch.snoozeMailboxId),
            ("junkMailboxId", patch.junkMailboxId),
        ].compactMap { field, id in id.map { (field, $0) } }
    }
}

// MARK: - Writes from rows

extension AccountWrite {
    /// The write that leaves `record` exactly as it is, for a change of a few columns.
    init(record: AccountRecord) {
        self.init(
            identity: record.identity,
            remoteId: record.remoteId,
            name: record.name,
            emailAddress: record.emailAddress,
            sortOrder: record.sortOrder,
            draftsMailboxId: record.draftsMailboxId,
            sentMailboxId: record.sentMailboxId,
            trashMailboxId: record.trashMailboxId,
            archiveMailboxId: record.archiveMailboxId,
            junkMailboxId: record.junkMailboxId,
            snoozeMailboxId: record.snoozeMailboxId,
            showSubscribedOnly: record.showSubscribedOnly,
            quotaPercentage: record.quotaPercentage,
            signature: record.signature,
            rawJSON: record.rawJSON,
            editorMode: record.editorMode,
            signatureAboveQuote: record.signatureAboveQuote,
            trashRetentionDays: record.trashRetentionDays,
            searchBody: record.searchBody,
            classificationEnabled: record.classificationEnabled,
            imipCreate: record.imipCreate,
            sieveEnabled: record.sieveEnabled,
            signatureMode: record.signatureMode,
            smimeCertificateRemoteId: record.smimeCertificateRemoteId,
            outOfOfficeFollowsSystem: record.outOfOfficeFollowsSystem,
            provisioningId: record.provisioningId,
            isDelegated: record.isDelegated
        )
    }

    /// `patch` applied. Special mailboxes take the server numbers the account columns hold.
    mutating func apply(_ patch: AccountPatch, remoteMailboxIds: [String: Int64]) {
        if let value = patch.editorMode { editorMode = value }
        if let value = patch.order { sortOrder = value }
        if let value = patch.showSubscribedOnly { showSubscribedOnly = value }
        if let value = remoteMailboxIds["draftsMailboxId"] { draftsMailboxId = value }
        if let value = remoteMailboxIds["sentMailboxId"] { sentMailboxId = value }
        if let value = remoteMailboxIds["trashMailboxId"] { trashMailboxId = value }
        if let value = remoteMailboxIds["archiveMailboxId"] { archiveMailboxId = value }
        if let value = remoteMailboxIds["snoozeMailboxId"] { snoozeMailboxId = value }
        if let value = remoteMailboxIds["junkMailboxId"] { junkMailboxId = value }
        if let value = patch.signatureAboveQuote { signatureAboveQuote = value }
        if let value = patch.trashRetentionDays { trashRetentionDays = value }
        if let value = patch.searchBody { searchBody = value }
        if let value = patch.classificationEnabled { classificationEnabled = value }
        if let value = patch.imipCreate { imipCreate = value }
    }
}

extension MailboxWrite {
    /// The write that leaves `record` exactly as it is.
    init(record: MailboxRecord) {
        self.init(
            accountId: record.accountId,
            remoteId: record.remoteId,
            name: record.name,
            delimiter: record.delimiter,
            displayName: record.displayName,
            specialRole: record.specialRole,
            specialUseJSON: record.specialUseJSON,
            attributesJSON: record.attributesJSON,
            isSubscribed: record.isSubscribed,
            isSelectable: record.isSelectable,
            syncInBackground: record.syncInBackground,
            unreadCount: record.unreadCount,
            totalCount: record.totalCount,
            cacheBuster: record.cacheBuster,
            rawJSON: record.rawJSON
        )
    }
}
