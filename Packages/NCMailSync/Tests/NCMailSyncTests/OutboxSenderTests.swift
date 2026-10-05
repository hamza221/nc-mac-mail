// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// ADR-0066 against a fake transport answering with recorded fixtures.
@Suite("Outbox sender")
struct OutboxSenderTests {
    // MARK: - Drafts

    @Test func saveDraftDebouncesToOneCreateThenUpdates() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()

        await fixture.sender.saveDraft(id)
        await fixture.sender.saveDraft(id)
        await fixture.sender.saveDraft(id)
        await fixture.sender.settle()
        #expect(await fixture.paths() == ["POST /index.php/apps/mail/api/drafts"])

        var draft = try #require(try await fixture.draft(id))
        #expect(draft.remoteId == 52)
        #expect(draft.savedAt == draft.updatedAt)
        #expect(draft.syncError == nil)

        // An unchanged draft sends nothing; an edited one is a PUT to the same server draft.
        await fixture.sender.saveDraft(id)
        await fixture.sender.settle()
        #expect(await fixture.transport.sendCount == 1)

        draft.subject = "Edited"
        draft.updatedAt += 7
        try await fixture.store.update(draft: draft)
        await fixture.sender.saveDraft(id)
        await fixture.sender.settle()
        let last = try #require(await fixture.transport.requests.last)
        #expect(last.httpMethod == "PUT")
        #expect(last.url?.path.hasSuffix("/api/drafts/52") == true)
        #expect(try OutboxTest.body(last)["subject"] as? String == "Edited")
    }

    @Test func aDraftTheServerMovedToIMAPIsRecreated() async throws {
        let fixture = try await OutboxTest.make()
        await fixture.transport.stub(OutboxTest.updateDraft, with: .json(#"{"status":"fail","data":[]}"#, status: 404))
        await fixture.transport.stub(OutboxTest.createDraft, with: try .fixture("draft-created.json", status: 201))
        let id = try await fixture.makeDraft()
        var draft = try #require(try await fixture.draft(id))
        draft.remoteId = 7
        draft.replacesMessageId = 4_242
        try await fixture.store.update(draft: draft)

        await fixture.sender.saveDraft(id)
        await fixture.sender.settle()

        let requests = await fixture.transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "POST"])
        #expect(try OutboxTest.body(requests[1])["draftId"] as? Int == 4_242)
        #expect(try await fixture.draft(id)?.remoteId == 52)
    }

    @Test func aFailedSaveIsRecordedAndRetriedOnReconnect() async throws {
        let fixture = try await OutboxTest.make()
        await fixture.transport.fail(
            OutboxTest.createDraft,
            times: 1,
            then: try .fixture("draft-created.json", status: 201)
        )
        let id = try await fixture.makeDraft()

        await fixture.sender.saveDraft(id)
        await fixture.sender.settle()
        #expect(try await fixture.draft(id)?.syncError == "transport")
        #expect(try await fixture.draft(id)?.remoteId == nil)

        await fixture.sender.apply(conditions: MirrorConditions(isOffline: true))
        await fixture.sender.apply(conditions: MirrorConditions(isOffline: false))
        await fixture.sender.settle()
        #expect(try await fixture.draft(id)?.remoteId == 52)
        #expect(try await fixture.draft(id)?.syncError == nil)
    }

    @Test func closeDraftMovesItToIMAPAndDropsTheRow() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()

        await fixture.sender.closeDraft(id)

        #expect(
            await fixture.paths() == [
                "POST /index.php/apps/mail/api/drafts",
                "POST /index.php/apps/mail/api/drafts/move/52",
            ]
        )
        #expect(try await fixture.draft(id) == nil)
        #expect(fixture.syncedMailboxes.all == [fixture.draftsId])
    }

    @Test func closeDraftOfflineMovesOnReconnect() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        await fixture.sender.apply(conditions: MirrorConditions(isOffline: true))

        await fixture.sender.closeDraft(id)
        #expect(await fixture.transport.sendCount == 0)
        #expect(try await fixture.draft(id)?.sendState == "closing")

        await fixture.sender.apply(conditions: MirrorConditions(isOffline: false))
        await fixture.sender.settle()
        #expect(await fixture.transport.sendCount == 2)
        #expect(try await fixture.draft(id) == nil)
    }

    @Test func discardDeletesTheServerDraftAndTheRow() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        await fixture.sender.saveDraft(id)
        await fixture.sender.settle()

        await fixture.sender.discardDraft(id)
        #expect(await fixture.paths().last == "DELETE /index.php/apps/mail/api/drafts/52")
        #expect(try await fixture.draft(id) == nil)
    }

    // MARK: - Sending

    @Test func sendUploadsThenEnqueuesThenSendsThenSyncsSent() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID()).txt")
        try Data("attached".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try await fixture.store.insert(
            draftAttachment: DraftAttachmentRecord(
                draftId: id, fileName: "a.txt", mime: "text/plain", localPath: file.path
            )
        )

        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.settle()

        let requests = await fixture.transport.requests
        #expect(
            await fixture.paths() == [
                "POST /index.php/apps/mail/api/attachments",
                "POST /index.php/apps/mail/api/drafts",
                "POST /index.php/apps/mail/api/outbox/from-draft/52",
                "POST /index.php/apps/mail/api/outbox/52",
            ]
        )
        // The draft carries the uploaded attachment by server id, and a pinned sendAt.
        let draftBody = try OutboxTest.body(requests[1])
        let attachments = try #require(draftBody["attachments"] as? [[String: Any]])
        #expect(attachments.first?["type"] as? String == "local")
        #expect(attachments.first?["id"] as? Int == 9)
        #expect(draftBody["sendAt"] as? Int != nil)
        #expect(try OutboxTest.body(requests[2])["sendAt"] as? Int == draftBody["sendAt"] as? Int)

        #expect(try await fixture.draft(id) == nil)
        #expect(try await fixture.store.attachments(draftId: id).isEmpty)
        #expect(fixture.outboxRefreshes.all.count == 1)
        #expect(fixture.syncedMailboxes.all == [fixture.sentId])
        _ = attachment
    }

    @Test func undoInsideTheWindowLeavesNoServerTrace() async throws {
        let fixture = try await OutboxTest.make(sleepsForReal: true)
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()

        try await fixture.sender.send(draftId: id, sendAt: nil)
        #expect(try await fixture.draft(id)?.sendState == "undo")
        fixture.clock.advance(by: 9)
        #expect(await fixture.sender.undoSend(draftId: id))
        await fixture.sender.settle()

        #expect(await fixture.transport.sendCount == 0)
        let draft = try #require(try await fixture.draft(id))
        #expect(draft.sendState == nil)
        #expect(draft.sendRequestedAt == nil)
    }

    /// The composer autosaves while the send request is in flight: the request writes only
    /// send columns, so the user's last content survives on the row next to the send intent.
    @Test func autosaveRacingTheSendRequestKeepsTheLastContent() async throws {
        let fixture = try await OutboxTest.make(sleepsForReal: true)
        let id = try await fixture.makeDraft()
        let base = try #require(try await fixture.draft(id))
        let store = fixture.store

        async let edits: Void = {
            for edit in 0..<50 {
                var draft = base
                draft.subject = "edit-\(edit)"
                draft.bodyPlain = "body-\(edit)"
                draft.updatedAt = base.updatedAt + Int64(edit) + 1
                try await store.updateDraftContent(draft)
            }
        }()
        try await fixture.sender.send(draftId: id, sendAt: Date(timeIntervalSince1970: 2_000_000_000))
        try await edits

        let row = try #require(try await fixture.draft(id))
        #expect(row.subject == "edit-49")
        #expect(row.bodyPlain == "body-49")
        #expect(row.sendState == "undo")
        #expect(row.sendRequestedAt != nil)
        await fixture.sender.stop()
    }

    /// Deterministic half of the race: a content write between the request's read and its
    /// write is simulated by writing content first and asserting the request leaves it.
    @Test func theSendRequestWritesOnlySendColumns() async throws {
        let fixture = try await OutboxTest.make(sleepsForReal: true)
        let id = try await fixture.makeDraft()
        var edited = try #require(try await fixture.draft(id))
        edited.subject = "latest"
        edited.bodyPlain = "latest body"
        edited.updatedAt += 5
        try await fixture.store.updateDraftContent(edited)
        try await fixture.store.setDraftSync(id: id, remoteId: 77, savedAt: 3, syncError: "old")

        try await fixture.sender.send(draftId: id, sendAt: Date(timeIntervalSince1970: 2_000_000_000))

        let row = try #require(try await fixture.draft(id))
        #expect(row.subject == "latest")
        #expect(row.bodyPlain == "latest body")
        #expect(row.updatedAt == edited.updatedAt)
        #expect(row.remoteId == 77)
        #expect(row.savedAt == 3)
        #expect(row.syncError == nil)
        #expect(row.sendAt == 2_000_000_000)
        #expect(row.sendState == "undo")
        await fixture.sender.stop()
    }

    @Test func undoAfterTheWindowIsRefused() async throws {
        let fixture = try await OutboxTest.make(sleepsForReal: true)
        let id = try await fixture.makeDraft()
        try await fixture.sender.send(draftId: id, sendAt: nil)
        fixture.clock.advance(by: 10)
        #expect(await fixture.sender.undoSend(draftId: id) == false)
        await fixture.sender.stop()
    }

    @Test func sendWithoutRecipientsDoesNotStart() async throws {
        let fixture = try await OutboxTest.make()
        let id = try await fixture.makeDraft()
        try await fixture.store.replaceRecipients([], draftId: id)
        await #expect(throws: OutboxError.noRecipients) {
            try await fixture.sender.send(draftId: id, sendAt: nil)
        }
        #expect(try await fixture.draft(id)?.sendState == nil)
    }

    @Test func aFailedUploadFailsTheSendBeforeTheOutbox() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        try await fixture.store.insert(
            draftAttachment: DraftAttachmentRecord(
                draftId: id, fileName: "gone.pdf", localPath: "/nonexistent/\(UUID()).pdf"
            )
        )

        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.settle()

        #expect(await fixture.transport.sendCount == 0)
        let draft = try #require(try await fixture.draft(id))
        #expect(draft.sendState == "failed")
        #expect(draft.syncError?.hasPrefix("attachment upload failed") == true)
    }

    @Test func aRejectedUploadFailsTheSendWithTheServerReason() async throws {
        let fixture = try await OutboxTest.make()
        // First registered wins, so the rejection goes in before the happy path.
        await fixture.transport.stub(
            RequestMatcher.multipart,
            with: .json(#"{"status":"error","message":"Too large"}"#, status: 413)
        )
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID()).bin")
        try Data(count: 16).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await fixture.store.insert(
            draftAttachment: DraftAttachmentRecord(draftId: id, fileName: "big.bin", localPath: file.path)
        )

        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.settle()

        #expect(await fixture.paths() == ["POST /index.php/apps/mail/api/attachments"])
        #expect(try await fixture.draft(id)?.sendState == "failed")
        #expect(try await fixture.draft(id)?.syncError == "attachment upload failed: Too large")
    }

    @Test func anOfflineSendWaitsQueuedAndGoesOutOnReconnect() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        await fixture.sender.apply(conditions: MirrorConditions(isOffline: true))

        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.settle()
        #expect(await fixture.transport.sendCount == 0)
        #expect(try await fixture.draft(id)?.sendState == "queued")

        await fixture.sender.apply(conditions: MirrorConditions(isOffline: false))
        await fixture.sender.settle()
        #expect(await fixture.paths().last == "POST /index.php/apps/mail/api/outbox/52")
        #expect(try await fixture.draft(id) == nil)
    }

    @Test func aDroppedConnectionLeavesTheSendQueued() async throws {
        let fixture = try await OutboxTest.make()
        await fixture.transport.fail(
            OutboxTest.createDraft,
            times: 1,
            then: try .fixture("draft-created.json", status: 201)
        )
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()

        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.settle()
        #expect(try await fixture.draft(id)?.sendState == "queued")

        await fixture.sender.apply(conditions: MirrorConditions(isOffline: true))
        await fixture.sender.apply(conditions: MirrorConditions(isOffline: false))
        await fixture.sender.settle()
        #expect(try await fixture.draft(id) == nil)
    }

    @Test func scheduledSendStaysOnTheServer() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        let when = Date(timeIntervalSince1970: TimeInterval(fixture.clock.seconds + 86_400))

        try await fixture.sender.send(draftId: id, sendAt: when)
        await fixture.sender.settle()

        let requests = await fixture.transport.requests
        #expect(
            await fixture.paths() == [
                "POST /index.php/apps/mail/api/drafts",
                "POST /index.php/apps/mail/api/outbox/from-draft/52",
            ]
        )
        #expect(try OutboxTest.body(requests[1])["sendAt"] as? Int == Int(when.timeIntervalSince1970))
        #expect(try await fixture.draft(id) == nil)
        #expect(fixture.outboxRefreshes.all.count == 1)
        #expect(fixture.syncedMailboxes.all.isEmpty)
    }

    @Test func aServerSendFailureHandsTheMessageToTheOutbox() async throws {
        let fixture = try await OutboxTest.make()
        await fixture.transport.stub(
            OutboxTest.sendOutbox,
            with: .json(#"{"status":"error","message":"Could not send message","data":[]}"#, status: 500)
        )
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()

        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.settle()

        #expect(try await fixture.draft(id) == nil)
        #expect(fixture.outboxRefreshes.all.count == 1)
    }

    // MARK: - Quit and relaunch

    @Test func aQuitInsideTheWindowSendsOnRelaunchOnlyOnceElapsed() async throws {
        let fixture = try await OutboxTest.make(sleepsForReal: true)
        try await OutboxTest.stubHappyPath(fixture.transport)
        let id = try await fixture.makeDraft()
        try await fixture.sender.send(draftId: id, sendAt: nil)
        await fixture.sender.stop()  // quit

        // Relaunched 4 s later: still inside the window, still undoable, nothing sent.
        fixture.clock.advance(by: 4)
        let early = fixture.relaunched(sleepsForReal: true)
        await early.start()
        #expect(await fixture.transport.sendCount == 0)
        #expect(try await fixture.draft(id)?.sendState == "undo")
        await early.stop()

        // Relaunched after the window: it goes.
        fixture.clock.advance(by: 30)
        let late = fixture.relaunched()
        await late.start()
        await late.settle()
        #expect(await fixture.paths().last == "POST /index.php/apps/mail/api/outbox/52")
        #expect(try await fixture.draft(id) == nil)
    }

    @Test func aSendInterruptedAfterConversionIsFinishedNotDuplicated() async throws {
        let fixture = try await OutboxTest.make()
        let id = try await fixture.makeDraft()
        var draft = try #require(try await fixture.draft(id))
        draft.remoteId = 52
        draft.sendState = "sending"
        draft.sendRequestedAt = fixture.clock.seconds - 60
        try await fixture.store.update(draft: draft)
        // Converted already: no longer a draft, not convertible again, but in the outbox.
        await fixture.transport.stub(OutboxTest.fromDraft, with: .json(#"{"status":"fail","data":[]}"#, status: 404))
        await fixture.transport.stub(OutboxTest.updateDraft, with: .json(#"{"status":"fail","data":[]}"#, status: 404))
        await fixture.transport.stub(OutboxTest.getOutbox, with: try .fixture("outbox-message.json"))
        await fixture.transport.stub(OutboxTest.sendOutbox, with: try .fixture("outbox-sent.json", status: 202))

        await fixture.sender.start()
        await fixture.sender.settle()

        let paths = await fixture.paths()
        #expect(!paths.contains("POST /index.php/apps/mail/api/drafts"))
        #expect(paths.filter { $0 == "POST /index.php/apps/mail/api/outbox/52" }.count == 1)
        #expect(try await fixture.draft(id) == nil)
    }

    @Test func aSendThatAlreadyLeftIsNotSentAgain() async throws {
        let fixture = try await OutboxTest.make()
        let id = try await fixture.makeDraft()
        var draft = try #require(try await fixture.draft(id))
        draft.remoteId = 52
        draft.sendState = "sending"
        try await fixture.store.update(draft: draft)
        await fixture.transport.stub(OutboxTest.updateDraft, with: .json(#"{"status":"fail","data":[]}"#, status: 404))
        await fixture.transport.stub(OutboxTest.getOutbox, with: .json(#"{"status":"fail","data":[]}"#, status: 404))

        await fixture.sender.start()
        await fixture.sender.settle()

        #expect(
            await fixture.paths() == [
                "PUT /index.php/apps/mail/api/drafts/52",
                "GET /index.php/apps/mail/api/outbox/52",
            ])
        #expect(try await fixture.draft(id) == nil)
    }

    // MARK: - Server outbox actions

    @Test func outboxActionsAddressTheServerRow() async throws {
        let fixture = try await OutboxTest.make()
        try await OutboxTest.stubHappyPath(fixture.transport)
        try await fixture.store.replaceOutbox(
            [OutboxMessageRecord(accountId: fixture.accountId, remoteId: 52, failed: true, syncedAt: 0)],
            accountId: fixture.accountId
        )
        let local = try #require(try await fixture.store.outboxMessages().first?.id)

        try await fixture.sender.sendNow(outboxId: local)
        try await fixture.sender.copyToSent(outboxId: local)
        try await fixture.sender.deleteOutbox(outboxId: local)

        #expect(
            await fixture.paths() == [
                "POST /index.php/apps/mail/api/outbox/52",
                "POST /index.php/apps/mail/api/outbox/52",
                "DELETE /index.php/apps/mail/api/outbox/52",
            ]
        )
        #expect(fixture.outboxRefreshes.all.count == 3)
        #expect(fixture.syncedMailboxes.all == [fixture.sentId, fixture.sentId])

        await fixture.sender.apply(conditions: MirrorConditions(isOffline: true))
        await #expect(throws: OutboxError.offline) { try await fixture.sender.sendNow(outboxId: local) }
    }

    // MARK: - Request body

    @Test func theRequestBodyMapsEveryTable() throws {
        let draft = DraftRecord(
            id: 3, accountId: 1, remoteId: nil, subject: nil, bodyPlain: "p", isHtml: false,
            inReplyToMessageId: "<m@x>", requestMdn: true, createdAt: 0, updatedAt: 0, replacesMessageId: 77
        )
        let recipients = [
            DraftRecipientRecord(draftId: 3, kind: "cc", position: 0, email: "c@x.invalid"),
            DraftRecipientRecord(draftId: 3, kind: "to", position: 1, email: "b@x.invalid"),
            DraftRecipientRecord(draftId: 3, kind: "to", position: 0, email: "a@x.invalid", label: "A"),
        ]
        let attachments = [
            DraftAttachmentRecord(draftId: 3, fileName: "pending"),
            DraftAttachmentRecord(draftId: 3, fileName: "up", remoteAttachmentId: 9),
            DraftAttachmentRecord(
                draftId: 3, kind: "message", fileName: "fwd", payloadJSON: #"{"type":"message","id":5}"#
            ),
        ]
        let create = OutboxRequest.body(
            draft: draft, recipients: recipients, attachments: attachments,
            remoteAccountId: 11, aliasRemoteId: 4, sendAt: 99, isCreate: true
        )
        #expect(create.accountId == 11)
        #expect(create.subject == "")
        #expect(create.to.map(\.email) == ["a@x.invalid", "b@x.invalid"])
        #expect(create.cc.map(\.email) == ["c@x.invalid"])
        #expect(
            create.attachments == [
                .object(["type": .string("local"), "id": .int(9)]),
                .object(["type": .string("message"), "id": .int(5)]),
            ])
        #expect(create.aliasId == 4)
        #expect(create.draftId == 77)
        #expect(create.sendAt == 99)
        #expect(create.requestMdn)

        let update = OutboxRequest.body(
            draft: draft, recipients: recipients, attachments: [],
            remoteAccountId: 11, aliasRemoteId: nil, sendAt: nil, isCreate: false
        )
        #expect(update.draftId == nil)
    }
}
