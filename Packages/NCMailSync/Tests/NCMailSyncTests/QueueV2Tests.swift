// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// WS-22's acceptance: every v2 kind survives a quit and drains on reconnect, against the
/// real store and a fake transport answering with recorded fixtures.
@Suite("Queue v2 kinds")
struct QueueV2Tests {
    /// One of each kind, in an order whose later rows depend on earlier ones only through
    /// placeholders — which is exactly what has to survive a relaunch.
    private func everyKind(_ fixture: QueueV2Test.Fixture) async throws -> [MailOperation] {
        let ids = fixture.base.messageIds
        let rootA = try #require(try await fixture.base.message(6).threadRootId)
        let rootB = try #require(try await fixture.base.message(9).threadRootId)
        #expect(rootA != rootB)
        let loginId = fixture.loginId
        return [
            .setTag(messageIds: [ids[0]], imapLabel: "$label1"),
            .unsetTag(messageIds: [ids[1]], imapLabel: "$label1"),
            .createTag(displayName: "New", color: "#0000ff"),
            .updateTag(tagRemoteId: QueueV2Test.tagUpdated, displayName: "Work 2", color: "#123456"),
            .deleteTag(tagRemoteId: QueueV2Test.tagDeleted),
            .snooze(messageIds: [ids[2]], until: 2_000_000_000),
            .unsnooze(messageIds: [ids[3]]),
            .snoozeThread(rootId: rootA, until: 2_000_000_000),
            .unsnoozeThread(rootId: rootB),
            .createMailbox(name: "Projects"),
            .renameMailbox(mailboxId: fixture.base.archiveId, name: "Archive 2"),
            .moveMailbox(mailboxId: fixture.base.junkId, parentMailboxId: fixture.base.inboxId),
            .deleteMailbox(mailboxId: fixture.oldMailboxId),
            .setMailboxSubscribed(mailboxId: fixture.base.trashId, subscribed: false),
            .setMailboxSyncInBackground(mailboxId: fixture.base.inboxId, enabled: true),
            .clearMailbox(mailboxId: fixture.base.trashId),
            .markMailboxRead(mailboxId: fixture.base.inboxId),
            .setPreference(key: "sort-order", value: "oldest"),
            .patchAccount(AccountPatch(showSubscribedOnly: true, archiveMailboxId: fixture.base.archiveId)),
            .setSignature("Regards"),
            .createAlias(email: "new@example.invalid", name: "New"),
            .updateAlias(aliasRemoteId: QueueV2Test.aliasUpdated, email: "a2@example.invalid", name: "A2"),
            .setAliasSignature(aliasRemoteId: QueueV2Test.aliasUpdated, signature: "A sig"),
            .deleteAlias(aliasRemoteId: QueueV2Test.aliasDeleted),
            .createTextBlock(title: "New", content: "Body"),
            .updateTextBlock(textBlockRemoteId: QueueV2Test.blockUpdated, title: "Hi 2", content: "Hello 2"),
            .shareTextBlock(textBlockRemoteId: QueueV2Test.blockUpdated, shareWith: "bob", type: "user"),
            .unshareTextBlock(textBlockRemoteId: QueueV2Test.blockUpdated, shareWith: "carol"),
            .deleteTextBlock(textBlockRemoteId: QueueV2Test.blockDeleted),
            .createQuickAction(name: "New action"),
            .updateQuickAction(quickActionRemoteId: QueueV2Test.actionUpdated, name: "Triage 2"),
            .upsertActionStep(
                ActionStepIntent(quickActionRemoteId: QueueV2Test.actionUpdated, name: "markAsImportant", order: 3)),
            .upsertActionStep(
                ActionStepIntent(
                    quickActionRemoteId: QueueV2Test.actionUpdated, stepRemoteId: QueueV2Test.stepUpdated,
                    name: "applyTag", order: 1, tagRemoteId: QueueV2Test.tagUpdated
                )
            ),
            .deleteActionStep(quickActionRemoteId: QueueV2Test.actionUpdated, stepRemoteId: QueueV2Test.stepDeleted),
            .deleteQuickAction(quickActionRemoteId: QueueV2Test.actionDeleted),
            .addInternalAddress(address: "x@example.invalid", type: "individual"),
            .removeInternalAddress(address: "example.invalid", type: "domain"),
            .trustDomain(domain: "example.org", trusted: true),
            .sendMDN(messageId: ids[4]),
            .unsubscribe(messageId: ids[5]),
            .saveToFiles(messageId: ids[5], attachmentId: nil, targetPath: "/Mail"),
            .contactPut(
                QueueV2Test.davPayload(
                    loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/a.vcf",
                    body: "BEGIN:VCARD\r\nFN:A\r\nEND:VCARD\r\n")),
            .contactDelete(
                QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/b.vcf")),
            .addressBookCreate(QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/new/")),
            .addressBookUpdate(
                QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/")),
            .addressBookDelete(QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/old/")),
            .addressBookShare(
                QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/shared/")),
            .calendarPut(
                QueueV2Test.davPayload(
                    loginId, href: "/remote.php/dav/calendars/alice/personal/e.ics",
                    body: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")),
            .contactFavorite(
                QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/c.vcf")),
            .contactSocialAvatar(
                QueueV2Test.davPayload(loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/d.vcf")),
        ]
    }

    /// What each kind must have sent, as `METHOD path` predicates over the request log.
    private static let expectedRequests: [(OperationKind, String, @Sendable (String) -> Bool)] = [
        (.setTag, "PUT", { $0.contains("/messages/1/tags/") }),
        (.unsetTag, "DELETE", { $0.contains("/messages/2/tags/") }),
        (.createTag, "POST", { $0.hasSuffix("/api/tags") }),
        (.updateTag, "PUT", { $0.hasSuffix("/api/tags/5") }),
        (.deleteTag, "DELETE", { $0.hasSuffix("/tags/1/delete/6") }),
        (.snooze, "POST", { $0.hasSuffix("/messages/3/snooze") }),
        (.unsnooze, "POST", { $0.hasSuffix("/messages/4/unsnooze") }),
        (.snoozeThread, "POST", { $0.contains("/thread/") && $0.hasSuffix("/snooze") }),
        (.unsnoozeThread, "POST", { $0.contains("/thread/") && $0.hasSuffix("/unsnooze") }),
        (.createMailbox, "POST", { $0.hasSuffix("/api/mailboxes") }),
        (.renameMailbox, "PATCH", { $0.hasSuffix("/mailboxes/920") }),
        (.moveMailbox, "PATCH", { $0.hasSuffix("/mailboxes/922") }),
        (.deleteMailbox, "DELETE", { $0.hasSuffix("/mailboxes/924") }),
        (.setMailboxSubscribed, "PATCH", { $0.hasSuffix("/mailboxes/921") }),
        (.clearMailbox, "POST", { $0.hasSuffix("/mailboxes/921/clear") }),
        (.markMailboxRead, "POST", { $0.hasSuffix("/read") }),
        (.setPreference, "PUT", { $0.hasSuffix("/preferences/sort-order") }),
        (.patchAccount, "PATCH", { $0.hasSuffix("/api/accounts/1") }),
        (.setSignature, "PUT", { $0.hasSuffix("/accounts/1/signature") }),
        (.createAlias, "POST", { $0.hasSuffix("/accounts/1/aliases") }),
        (.updateAlias, "PUT", { $0.hasSuffix("/aliases/31") }),
        (.setAliasSignature, "PUT", { $0.hasSuffix("/aliases/31/signature") }),
        (.deleteAlias, "DELETE", { $0.hasSuffix("/aliases/32") }),
        (.createTextBlock, "POST", { $0.hasSuffix("/api/textBlocks") }),
        (.updateTextBlock, "PUT", { $0.hasSuffix("/textBlocks/41") }),
        (.shareTextBlock, "POST", { $0.hasSuffix("/textBlockshares") }),
        (.unshareTextBlock, "DELETE", { $0.hasSuffix("/textBlockshares/41") }),
        (.deleteTextBlock, "DELETE", { $0.hasSuffix("/textBlocks/42") }),
        (.createQuickAction, "POST", { $0.hasSuffix("/api/quick-actions") }),
        (.updateQuickAction, "PUT", { $0.hasSuffix("/quick-actions/51") }),
        (.upsertActionStep, "POST", { $0.hasSuffix("/api/action-step") }),
        (.upsertActionStep, "PUT", { $0.hasSuffix("/action-step/61") }),
        (.deleteActionStep, "DELETE", { $0.hasSuffix("/action-step/62") }),
        (.deleteQuickAction, "DELETE", { $0.hasSuffix("/quick-actions/52") }),
        (.addInternalAddress, "PUT", { $0.contains("/internalAddress/x@example.invalid") }),
        (.removeInternalAddress, "DELETE", { $0.contains("/internalAddress/example.invalid") }),
        (.trustDomain, "PUT", { $0.contains("/trustedsenders/example.org") }),
        (.sendMDN, "POST", { $0.hasSuffix("/messages/5/mdn") }),
        (.unsubscribe, "POST", { $0.hasSuffix("/list/unsubscribe/6") }),
        (.saveToFiles, "POST", { $0.hasSuffix("/messages/6/file") }),
    ]

    @Test func everyV2KindSurvivesQuitAndDrainsOnReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ws22-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "mirror.sqlite")

        let dav = RecordingDAVHandler()
        let fixture = try await QueueV2Test.make(url: url, dav: dav)
        let operations = try await everyKind(fixture)
        for operation in operations {
            try await fixture.queue.perform(operation, accountId: fixture.accountId)
        }
        let queued = try await fixture.rows()
        let queuedKinds = Set(queued.compactMap { OperationKind(rawValue: $0.kind) })
        let v2Kinds = Set(OperationKind.allCases).subtracting([
            .setFlags, .move, .delete, .moveThread, .deleteThread, .trustSender,
        ])
        #expect(queuedKinds == v2Kinds, "missing: \(v2Kinds.subtracting(queuedKinds))")
        #expect(await dav.applied.count == 9)

        // Offline: the network is gone, nothing is lost and nothing is counted twice.
        await fixture.transport.fail(.any, times: 10_000, then: .status(200))
        await fixture.drainer.drain()
        #expect(try await fixture.rows().count == queued.count)

        // Quit. A second store over the same file, a second drainer, a working network.
        let reopened = try MailStore(url: url)
        #expect(try await reopened.pendingOperations(accountId: fixture.accountId).count == queued.count)
        let online = FakeTransport()
        try await QueueV2Test.stubV2(online)
        let drainer = try fixture.drainer(store: reopened, transport: online)
        // The offline pass backed off the one row it tried; the relaunch comes later.
        fixture.base.clock.advance(by: 60)
        await drainer.drain()

        let left = try await reopened.pendingOperations(accountId: fixture.accountId)
        #expect(left.isEmpty, "left: \(left.map { "\($0.kind) \($0.lastError ?? "")" })")
        let sent = await online.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        for (kind, method, matches) in Self.expectedRequests {
            #expect(
                sent.contains { $0.hasPrefix(method + " ") && matches(String($0.dropFirst(method.count + 1))) },
                "\(kind.rawValue): no \(method) request matched"
            )
        }
        #expect(await Set(dav.sent.map(\.kind)) == Set(OperationKind.allCases.filter(\.isDAV)))

        // Creates wrote the server's ids over their placeholders.
        #expect(
            try await reopened.tags(accountId: fixture.accountId).contains {
                $0.remoteId == 13 && $0.imapLabel == "$fixture_tag"
            })
        #expect(try await reopened.mailboxes(accountId: fixture.accountId).contains { $0.remoteId == 19 })
        #expect(try await reopened.alias(accountId: fixture.accountId, remoteId: 11) != nil)
        #expect(try await reopened.textBlock(loginId: fixture.loginId, remoteId: 8) != nil)
        #expect(try await reopened.quickAction(accountId: fixture.accountId, remoteId: 10) != nil)
        reportQueueMeasurement(
            "\(queued.count) v2 rows across \(v2Kinds.count) kinds drained in \(sent.count) requests")
    }

    @Test func localEffectsLandWithTheRow() async throws {
        let fixture = try await QueueV2Test.make()
        try await fixture.queue.perform(
            .renameMailbox(mailboxId: fixture.base.archiveId, name: "Kept"), accountId: fixture.accountId)
        try await fixture.queue.perform(.setPreference(key: "layout", value: "vertical"), accountId: fixture.accountId)
        try await fixture.queue.perform(.createTextBlock(title: "Offline", content: "x"), accountId: fixture.accountId)
        try await fixture.queue.perform(
            .snooze(messageIds: [fixture.base.messageIds[0]], until: 1_900_000_000), accountId: fixture.accountId)

        #expect(try await fixture.store.mailbox(id: fixture.base.archiveId)?.name == "Kept")
        #expect(try await fixture.store.preferenceValue(key: "layout", loginId: fixture.loginId) == "vertical")
        #expect(
            try await fixture.store.textBlocks(loginId: fixture.loginId).contains {
                $0.title == "Offline" && $0.remoteId < 0
            })
        #expect(try await fixture.store.message(id: fixture.base.messageIds[0])?.mailboxId == fixture.snoozeId)
        #expect(try await fixture.store.snoozeUntil(messageId: fixture.base.messageIds[0]) == 1_900_000_000)
    }

    @Test func discardPutsEveryRowBack() async throws {
        let fixture = try await QueueV2Test.make()
        let message = fixture.base.messageIds[0]
        let inbox = try #require(try await fixture.store.message(id: message)).mailboxId
        try await fixture.queue.perform(
            .renameMailbox(mailboxId: fixture.base.archiveId, name: "Gone"), accountId: fixture.accountId)
        try await fixture.queue.perform(.setPreference(key: "layout", value: "vertical"), accountId: fixture.accountId)
        try await fixture.queue.perform(.createTextBlock(title: "Offline", content: "x"), accountId: fixture.accountId)
        try await fixture.queue.perform(
            .deleteAlias(aliasRemoteId: QueueV2Test.aliasDeleted), accountId: fixture.accountId)
        try await fixture.queue.perform(
            .snooze(messageIds: [message], until: 1_900_000_000), accountId: fixture.accountId)
        try await fixture.queue.perform(
            .contactPut(
                QueueV2Test.davPayload(fixture.loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/c.vcf")
            ),
            accountId: fixture.accountId
        )

        await fixture.drainer.discardAll()

        #expect(try await fixture.rows().isEmpty)
        #expect(try await fixture.store.mailbox(id: fixture.base.archiveId)?.name == "Archive")
        #expect(try await fixture.store.preferenceValue(key: "layout", loginId: fixture.loginId) == nil)
        #expect(try await fixture.store.textBlocks(loginId: fixture.loginId).allSatisfy { $0.remoteId > 0 })
        #expect(try await fixture.store.alias(accountId: fixture.accountId, remoteId: QueueV2Test.aliasDeleted) != nil)
        #expect(try await fixture.store.message(id: message)?.mailboxId == inbox)
        #expect(try await fixture.store.snoozeUntil(messageId: message) == nil)
        #expect(await fixture.dav.reverted == [.contactPut])
    }

    @Test func anOfflineCreateThenEditSendsTheServersId() async throws {
        let fixture = try await QueueV2Test.make()
        try await fixture.queue.perform(.createTextBlock(title: "Draft", content: "a"), accountId: fixture.accountId)
        let placeholder = try #require(
            try await fixture.store.textBlocks(loginId: fixture.loginId).first { $0.remoteId < 0 }
        ).remoteId
        try await fixture.queue.perform(
            .updateTextBlock(textBlockRemoteId: placeholder, title: "Draft 2", content: "b"),
            accountId: fixture.accountId
        )
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        let paths = await fixture.transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(paths.contains { $0.hasPrefix("PUT") && $0.hasSuffix("/textBlocks/8") })
        #expect(try await fixture.store.textBlock(loginId: fixture.loginId, remoteId: 8)?.title == "Draft 2")
    }

    @Test func anOfflineCreateThenRenameKeepsTheRenameAfterDrain() async throws {
        let fixture = try await QueueV2Test.make()
        try await fixture.queue.perform(.createMailbox(name: "X"), accountId: fixture.accountId)
        let created = try #require(
            try await fixture.store.mailboxes(accountId: fixture.accountId).first { $0.remoteId < 0 })
        try await fixture.queue.perform(.renameMailbox(mailboxId: created.id, name: "Y"), accountId: fixture.accountId)
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        let mailbox = try #require(
            try await fixture.store.mailboxes(accountId: fixture.accountId).first { $0.id == created.id })
        #expect(mailbox.remoteId == 19)
        #expect(mailbox.displayName == "Y")
    }

    @Test func anOfflineCreateWithNoLaterEditTakesTheServersRow() async throws {
        let fixture = try await QueueV2Test.make()
        try await fixture.queue.perform(.createMailbox(name: "X"), accountId: fixture.accountId)
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        let mailbox = try #require(
            try await fixture.store.mailboxes(accountId: fixture.accountId).first { $0.remoteId == 19 })
        #expect(mailbox.displayName == "FixtureScratch 1791062118")
    }

    @Test func anOfflineCreateThenUpdateTagKeepsTheUpdateAfterDrain() async throws {
        let fixture = try await QueueV2Test.make()
        try await fixture.queue.perform(.createTag(displayName: "X", color: "#000000"), accountId: fixture.accountId)
        let tag = try #require(try await fixture.store.tags(accountId: fixture.accountId).first { $0.remoteId < 0 })
        try await fixture.queue.perform(
            .updateTag(tagRemoteId: tag.remoteId, displayName: "Y", color: "#ffffff"), accountId: fixture.accountId)
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        let drained = try #require(
            try await fixture.store.tags(accountId: fixture.accountId).first { $0.remoteId == 13 })
        #expect(drained.displayName == "Y")
        #expect(drained.color == "#ffffff")
    }

    /// WS-31's offline flow: a new "Snoozed" mailbox, made the snooze mailbox, then used.
    private func queueOfflineSnoozeSetup(_ fixture: QueueV2Test.Fixture) async throws -> Int64 {
        try await fixture.queue.perform(.createMailbox(name: "Snoozed"), accountId: fixture.accountId)
        let created = try #require(
            try await fixture.store.mailboxes(accountId: fixture.accountId).first { $0.remoteId < 0 })
        try await fixture.queue.perform(
            .patchAccount(AccountPatch(snoozeMailboxId: created.id)), accountId: fixture.accountId)
        try await fixture.queue.perform(
            .snooze(messageIds: [fixture.base.messageIds[0]], until: 1_900_000_000), accountId: fixture.accountId)
        return created.remoteId
    }

    @Test func anOfflineSnoozeMailboxSendsOnlyTheServersId() async throws {
        let fixture = try await QueueV2Test.make()
        let placeholder = try await queueOfflineSnoozeSetup(fixture)
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        let requests = await fixture.transport.requests
        let paths = requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        let create = try #require(paths.firstIndex { $0.hasPrefix("POST") && $0.hasSuffix("/api/mailboxes") })
        let patch = try #require(paths.firstIndex { $0.hasPrefix("PATCH") && $0.hasSuffix("/api/accounts/1") })
        let snooze = try #require(paths.firstIndex { $0.hasSuffix("/snooze") })
        #expect(create < patch && patch < snooze)
        for request in requests {
            let text = (request.url?.absoluteString ?? "") + String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!text.contains(String(placeholder)), "placeholder leaked: \(text)")
        }
        let patchBody = String(decoding: requests[patch].httpBody ?? Data(), as: UTF8.self)
        #expect(patchBody.contains(#""snoozeMailboxId":19"#))
        let snoozeBody = String(decoding: requests[snooze].httpBody ?? Data(), as: UTF8.self)
        #expect(snoozeBody.contains(#""destMailboxId":19"#))
        #expect(try await fixture.store.account(id: fixture.accountId)?.snoozeMailboxId == 19)
    }

    @Test func anUnresolvedMailboxPlaceholderDefersTheDependentOperation() async throws {
        let fixture = try await QueueV2Test.make()
        let placeholder = try await queueOfflineSnoozeSetup(fixture)
        await fixture.transport.stub(.method("POST") && .pathSuffix("/api/mailboxes"), with: .status(500))
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()

        let rows = try await fixture.rows()
        #expect(Set(rows.map(\.kind)) == ["createMailbox", "patchAccount", "snooze"])
        let requests = await fixture.transport.requests
        #expect(!requests.contains { $0.httpMethod == "PATCH" || ($0.url?.path ?? "").hasSuffix("/snooze") })
        for request in requests {
            let text = (request.url?.absoluteString ?? "") + String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!text.contains(String(placeholder)))
        }
    }

    @Test func anUnsnoozeMovesTheMessageBackWhereTheSnoozeTookItFrom() async throws {
        let fixture = try await QueueV2Test.make()
        let message = fixture.base.messageIds[0]
        let source = try #require(try await fixture.store.message(id: message)).mailboxId
        try await fixture.queue.perform(
            .snooze(messageIds: [message], until: 1_900_000_000), accountId: fixture.accountId)
        #expect(try await fixture.store.message(id: message)?.mailboxId == fixture.snoozeId)

        try await fixture.queue.perform(.unsnooze(messageIds: [message]), accountId: fixture.accountId)
        #expect(try await fixture.store.message(id: message)?.mailboxId == source)
        #expect(try await fixture.store.snoozeUntil(messageId: message) == nil)

        await fixture.drainer.discardAll()
        #expect(try await fixture.store.message(id: message)?.mailboxId == source)
    }

    @Test func anUnsnoozeWithNoQueuedSnoozeGoesToTheInbox() async throws {
        let fixture = try await QueueV2Test.make()
        let message = fixture.base.messageIds[0]
        try await fixture.queue.perform(
            .snooze(messageIds: [message], until: 1_900_000_000), accountId: fixture.accountId)
        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()
        #expect(try await fixture.rows().isEmpty)

        try await fixture.queue.perform(.unsnooze(messageIds: [message]), accountId: fixture.accountId)
        #expect(try await fixture.store.message(id: message)?.mailboxId == fixture.base.inboxId)

        await fixture.drainer.discardAll()
        #expect(try await fixture.store.message(id: message)?.mailboxId == fixture.snoozeId)
    }

    @Test func settersCollapseAndADeleteAbsorbsItsUpdates() async throws {
        let fixture = try await QueueV2Test.make()
        try await fixture.queue.perform(
            .patchAccount(AccountPatch(showSubscribedOnly: true)), accountId: fixture.accountId)
        try await fixture.queue.perform(.patchAccount(AccountPatch(searchBody: true)), accountId: fixture.accountId)
        try await fixture.queue.perform(
            .updateTextBlock(textBlockRemoteId: QueueV2Test.blockDeleted, title: "x", content: "y"),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .deleteTextBlock(textBlockRemoteId: QueueV2Test.blockDeleted), accountId: fixture.accountId)
        let href = "/remote.php/dav/addressbooks/users/alice/contacts/m.vcf"
        try await fixture.queue.perform(
            .contactPut(QueueV2Test.davPayload(fixture.loginId, href: href, body: "one", edited: ["FN"])),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .contactPut(QueueV2Test.davPayload(fixture.loginId, href: href, body: "two", edited: ["EMAIL"])),
            accountId: fixture.accountId
        )

        let pending = try await fixture.queue.pendingDAVWrites(loginId: fixture.loginId)
        #expect(pending.count == 1)
        #expect(pending.first?.payload.body == "two")
        #expect(pending.first?.payload.editedProperties == ["FN", "EMAIL"])

        try await QueueV2Test.stubV2(fixture.transport)
        await fixture.drainer.drain()
        let requests = await fixture.transport.requests
        let patches = requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 1)
        let body = try QueueTest.body(try #require(patches.first))
        #expect(body["showSubscribedOnly"] as? Bool == true)
        #expect(body["searchBody"] as? Bool == true)
        #expect(!requests.contains { $0.httpMethod == "PUT" && ($0.url?.path ?? "").hasSuffix("/textBlocks/42") })
        #expect(requests.contains { $0.httpMethod == "DELETE" && ($0.url?.path ?? "").hasSuffix("/textBlocks/42") })
        #expect(await fixture.dav.sent.count == 1)
    }

    @Test func aDAVConflictIsParkedVisibleAndRetryable() async throws {
        let fixture = try await QueueV2Test.make()
        await fixture.dav.failNextSends(with: [DAVError.preconditionFailed])
        try await fixture.queue.perform(
            .contactPut(
                QueueV2Test.davPayload(fixture.loginId, href: "/remote.php/dav/addressbooks/users/alice/contacts/k.vcf")
            ),
            loginId: fixture.loginId
        )
        await fixture.drainer.drain()

        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.lastError == DAVWrite.conflictMarker)
        #expect(await fixture.drainer.summary().failing == 1)
        #expect(try await fixture.queue.pendingDAVWrites(loginId: fixture.loginId).first?.isConflicted == true)

        // Parked: another pass does not send it again.
        await fixture.drainer.drain()
        #expect(await fixture.dav.sent.isEmpty)

        await fixture.drainer.retryAll()
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.dav.sent.count == 1)
    }

    @Test func contactKindsNeedAHandler() async throws {
        let base = try await QueueTest.make()
        let login = try await base.store.ensureLogin(MailStoreFixtures.identity)
        await #expect(throws: OperationError.self) {
            try await base.queue.perform(
                .contactDelete(QueueV2Test.davPayload(try #require(login.id), href: "/x.vcf")),
                accountId: base.accountId
            )
        }
        #expect(try await base.rows().isEmpty)
    }

    @Test func aSnoozeNeedsASnoozeMailbox() async throws {
        let base = try await QueueTest.make()
        await #expect(throws: OperationError.self) {
            try await base.queue.perform(.snooze(messageIds: [base.messageIds[0]], until: 1), accountId: base.accountId)
        }
    }

    @Test func davSenderSpeaksPlainDAV() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: StubResponse(status: 201, body: Data(), headers: ["ETag": "\"2\""]))
        let client = DAVClient(
            server: try #require(URL(string: MirrorTest.server)),
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: transport
        )
        let sender = DAVWriteSender(client: client)
        let payload = QueueV2Test.davPayload(
            1, href: "/remote.php/dav/addressbooks/users/alice/contacts/s.vcf", body: "BEGIN:VCARD\r\nEND:VCARD\r\n")
        let etag = try await sender.send(DAVWrite(operationId: 1, kind: .contactPut, accountId: 1, payload: payload))
        #expect(etag == "\"2\"")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"1\"")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/vcard") == true)
    }
}

/// A scratch lifecycle of queued v2 kinds against the real server, created and removed in one
/// drain (ADR-0080). Off by default.
///
/// ```
/// NCMAIL_LIVE_SYNC=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter queuedCreatesAndDeletesDrainLive
/// ```
@Suite("Queue v2 against a live server")
struct QueueV2LiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_SYNC"]

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: QueueV2LiveTests.serverEnvironment != nil))
    func queuedCreatesAndDeletesDrainLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_SYNC"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "measurement"
        )
        let identity = ServerIdentity(serverURL: server, loginName: user)
        let account = try #require(
            try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity).first
        )
        let login = try await store.ensureLogin(identity)
        let loginId = try #require(login.id)
        let queue = MutationQueue(store: store)
        let drainer = OperationDrainer(store: store, client: client, accountId: account.id)

        // Offline: everything queued against placeholders.
        try await queue.perform(.createTextBlock(title: "WS-22 scratch", content: "queued offline"), loginId: loginId)
        let block = try #require(try await store.textBlocks(loginId: loginId).first { $0.remoteId < 0 })
        try await queue.perform(
            .updateTextBlock(textBlockRemoteId: block.remoteId, title: "WS-22 scratch 2", content: "edited offline"),
            loginId: loginId
        )
        try await queue.perform(.createTag(displayName: "WS-22 scratch", color: "#0082c9"), accountId: account.id)
        let tag = try #require(try await store.tags(accountId: account.id).first { $0.remoteId < 0 })
        try await queue.perform(
            .updateTag(tagRemoteId: tag.remoteId, displayName: "WS-22 scratch 2", color: "#c90082"),
            accountId: account.id)
        let queued = try await store.pendingOperations(accountId: account.id).count

        let start = ContinuousClock.now
        await drainer.drain()
        let created = ContinuousClock.now - start
        #expect(try await store.pendingOperations(accountId: account.id).isEmpty)
        let realBlock = try #require(
            try await store.textBlocks(loginId: loginId).first { $0.title == "WS-22 scratch 2" })
        let realTag = try #require(
            try await store.tags(accountId: account.id).first { $0.displayName == "WS-22 scratch 2" })
        #expect(realBlock.remoteId > 0)
        #expect(realTag.remoteId > 0)

        // Clean up through the queue too.
        try await queue.perform(.deleteTextBlock(textBlockRemoteId: realBlock.remoteId), loginId: loginId)
        try await queue.perform(.deleteTag(tagRemoteId: realTag.remoteId), accountId: account.id)
        let cleanStart = ContinuousClock.now
        await drainer.drain()
        let cleaned = ContinuousClock.now - cleanStart
        #expect(try await store.pendingOperations(accountId: account.id).isEmpty)
        reportQueueMeasurement("live: \(queued) queued v2 rows drained in \(created); 2 deletes in \(cleaned)")
    }
}
