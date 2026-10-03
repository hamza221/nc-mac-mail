// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailTestSupport
import Testing

@testable import NCMailNet

// Every WS-16 endpoint, replayed through `MailClient` against the bytes the
// recorder wrote, with the HTTP status the live server answered. This is the
// decode test the brief asks for: the endpoint's own `Response` type, its own
// verb, the client's own status mapping — not a model decoded in isolation.
//
// Fixtures are re-recorded per run and the dev server's content drifts, so
// these assert shape and types, never counts or text.

/// Replays one fixture for every request and returns the client.
private func replaying(_ fixture: String, status: Int = 200) async throws -> MailClient {
    let transport = FakeTransport()
    await transport.stub(.any, with: try .fixture(fixture, status: status))
    return MailClient.testing(transport: transport)
}

@Suite("v2 account endpoints through the client")
struct AccountEndpointReplayTests {
    @Test("PATCH answers the bare account")
    func patchAccount() async throws {
        let account = try await replaying("account-patch.json")
            .patch(.patchAccount(id: 1), body: PatchAccountRequest(showSubscribedOnly: false))
        #expect(account.value.id > 0)
    }

    @Test("signature and S/MIME link answer nothing worth reading")
    func signatureAndSmime() async throws {
        _ = try await replaying("account-signature.json")
            .put(.setAccountSignature(accountId: 1), body: SignatureRequest(signature: nil))
        _ = try await replaying("account-smime-certificate.json")
            .put(.setAccountSmimeCertificate(accountId: 1), body: SmimeCertificateLinkRequest(smimeCertificateId: nil))
    }

    @Test("quota and the connection test")
    func quotaAndTest() async throws {
        let quota = try await replaying("account-quota.json").get(.quota(accountId: 1))
        #expect(quota.data.usage >= 0)
        let test = try await replaying("account-test.json").get(.testAccount(accountId: 1))
        #expect(test.data != nil)
    }

    @Test("alias list, create, update, signature and delete")
    func aliases() async throws {
        let list = try await replaying("aliases.json").get(.aliases(accountId: 1))
        #expect(list.allSatisfy { $0.id > 0 })
        let created = try await replaying("alias-created.json", status: 201)
            .post(.createAlias(accountId: 1), body: AliasRequest(alias: "a@example.com", aliasName: "A"))
        #expect(created.id > 0)
        let updated = try await replaying("alias-updated.json")
            .put(
                .updateAlias(accountId: 1, aliasId: created.id),
                body: AliasRequest(alias: "a@example.com", aliasName: "B"))
        #expect(updated.id == created.id)
        _ = try await replaying("alias-signature.json")
            .put(.setAliasSignature(accountId: 1, aliasId: created.id), body: SignatureRequest(signature: "x"))
        let deleted = try await replaying("alias-deleted.json").delete(.deleteAlias(accountId: 1, aliasId: created.id))
        #expect(deleted.id == created.id)
    }

    @Test("autoconfig: ISPDB, MX and the port probe")
    func autoconfig() async throws {
        let ispdb = try await replaying("autoconfig-ispdb.json")
            .get(.autoconfigISPDB(host: "example.com", email: "a@example.com"))
        #expect(ispdb.data?.imapConfig != nil)
        let mx = try await replaying("autoconfig-mx.json").get(.autoconfigMX(email: "a@example.com"))
        #expect(mx.data?.isEmpty == false)
        let test = try await replaying("autoconfig-test.json").get(.autoconfigTest(host: "example.com", port: 993))
        #expect(test.data != nil)
    }

    @Test("delegation list, grant and revoke")
    func delegation() async throws {
        let delegates = try await replaying("delegations.json").get(.delegations(accountId: 1))
        #expect(delegates.allSatisfy { !$0.userId.isEmpty })
        let granted = try await replaying("delegation-created.json", status: 201)
            .post(.grantDelegation(accountId: 1), body: DelegationRequest(userId: "alice"))
        #expect(granted.id > 0)
        #expect(!granted.userId.isEmpty)
        _ = try await replaying("delegation-deleted.json").delete(.revokeDelegation(accountId: 1, userId: "alice"))
    }

    @Test("delegating to yourself is a 400 carrying the server's message")
    func delegationToSelf() async throws {
        let client = try await replaying("error-delegation-self.json", status: 400)
        do {
            _ = try await client.post(.grantDelegation(accountId: 1), body: DelegationRequest(userId: "admin"))
            Issue.record("expected a throw")
        } catch MailError.server(let status, let message) {
            #expect(status == 400)
            #expect(message?.isEmpty == false)
        }
    }

    @Test("the OAuth state mint and the OCS account list")
    func oauthAndOCSList() async throws {
        let state = try await replaying("oauth-state.json")
            .post(.oauthState, body: OAuthStateRequest(accountId: 1))
        #expect(!state.data.state.isEmpty)
        let list = try await replaying("ocs-account-list.json").get(.ocsAccountList)
        #expect(list.data.allSatisfy { $0.id > 0 })
    }
}

@Suite("v2 mailbox endpoints through the client")
struct MailboxEndpointReplayTests {
    @Test("create and PATCH answer the mailbox")
    func createAndPatch() async throws {
        let created = try await replaying("mailbox-created.json")
            .post(.createMailbox, body: CreateMailboxRequest(accountId: 1, name: "Scratch"))
        #expect(created.value.id > 0)
        let patched = try await replaying("mailbox-patched.json")
            .patch(.patchMailbox(id: 7), body: PatchMailboxRequest(name: "Renamed"))
        #expect(patched.value.id > 0)
    }

    @Test("delete, clear, read and repair answer nothing worth reading")
    func emptyMutations() async throws {
        _ = try await replaying("mailbox-deleted.json").delete(.deleteMailbox(id: 7))
        _ = try await replaying("mailbox-cleared.json").post(.clearMailbox(id: 7))
        _ = try await replaying("mailbox-read.json").post(.markMailboxRead(id: 7))
        _ = try await replaying("mailbox-repaired.json").post(.repairMailbox(id: 7))
    }

    @Test("stats")
    func stats() async throws {
        let stats = try await replaying("mailbox-stats.json").get(.mailboxStats(id: 5))
        #expect(stats.unread <= stats.total)
    }
}

@Suite("v2 message and thread endpoints through the client")
struct MessageEndpointReplayTests {
    @Test("source, itineraries and dkim")
    func detail() async throws {
        let source = try await replaying("message-source.json").get(.messageSource(id: 1))
        #expect(!source.source.isEmpty)
        _ = try await replaying("message-itineraries.json").get(.itineraries(messageId: 1))
        _ = try await replaying("message-dkim.json").get(.dkim(messageId: 1))
    }

    @Test("export and the attachments zip hand back their bytes untouched")
    func bytes() async throws {
        for (fixture, endpoint) in [
            ("message-export.eml", Endpoint<Data>.exportMessage(id: 1)),
            ("message-attachments.zip", Endpoint<Data>.attachmentsZip(messageId: 1)),
        ] {
            let recorded = try FixtureBytes.data(fixture)
            let (data, _) = try await replaying(fixture).bytes(endpoint)
            #expect(data == recorded)
            #expect(!data.isEmpty)
        }
    }

    @Test("adding and removing a tag answers the tag")
    func tags() async throws {
        let added = try await replaying("message-tag-added.json")
            .put(.addMessageTag(messageId: 1, imapLabel: "$fixture_tag"))
        #expect(added.imapLabel.hasPrefix("$"))
        let removed = try await replaying("message-tag-removed.json")
            .delete(.removeMessageTag(messageId: 1, imapLabel: "$fixture_tag"))
        #expect(removed.id == added.id)
    }

    @Test("snooze, unsnooze and the Files saves answer nothing worth reading")
    func emptyMutations() async throws {
        let snooze = SnoozeRequest(unixTimestamp: 1, destMailboxId: 1)
        _ = try await replaying("message-snoozed.json").post(.snoozeMessage(id: 1), body: snooze)
        _ = try await replaying("message-unsnoozed.json").post(.unsnoozeMessage(id: 1))
        _ = try await replaying("thread-snoozed.json").post(.snoozeThread(messageId: 1), body: snooze)
        _ = try await replaying("thread-unsnoozed.json").post(.unsnoozeThread(messageId: 1))
        let target = TargetPathRequest(targetPath: "/")
        _ = try await replaying("attachment-saved-to-files.json")
            .post(.saveAttachmentToFiles(messageId: 1, attachmentId: "2"), body: target)
        _ = try await replaying("message-saved-to-files.json").post(.saveMessageToFiles(messageId: 1), body: target)
    }

    @Test("a receipt for a message that asked for none is the server's 500")
    func mdnWithoutHeader() async throws {
        let client = try await replaying("message-mdn.json", status: 500)
        do {
            _ = try await client.post(.sendMDN(messageId: 1))
            Issue.record("expected a throw")
        } catch MailError.server(let status, let message) {
            #expect(status == 500)
            #expect(message?.isEmpty == false)
        }
    }

    @Test("unsubscribing from a message with no one-click header is forbidden")
    func unsubscribeWithoutHeader() async throws {
        let client = try await replaying("unsubscribe.json", status: 403)
        await #expect(throws: MailError.self) {
            _ = try await client.post(.unsubscribe(messageId: 1))
        }
    }

    @Test("LLM routes answer 204 without a provider; the client builds nil")
    func llmWithoutProvider() async throws {
        let reply = try await replaying("message-smartreply.json", status: 204).get(.smartReply(messageId: 1))
        #expect(reply.data == nil)
        let summary = try await replaying("thread-summary.json", status: 204).get(.threadSummary(messageId: 1))
        #expect(summary.data == nil)
        let event = try await replaying("thread-eventdata.json").get(.threadEventData(messageId: 1))
        #expect(event.data == nil)
    }
}

@Suite("v2 compose endpoints through the client")
struct ComposeEndpointReplayTests {
    private let draft = ComposeMessageRequest(accountId: 1, subject: "s", bodyPlain: "b", isHtml: false)

    @Test("draft create, update, move and delete — the last three answer 202")
    func drafts() async throws {
        let created = try await replaying("draft-created.json", status: 201).post(.createDraft, body: draft)
        #expect(created.data.value.type == 1)
        // 202 with the success envelope is a success, not a sync in progress.
        let updated = try await replaying("draft-updated.json", status: 202)
            .put(.updateDraft(id: created.data.value.id), body: draft)
        #expect(updated.data.value.id == created.data.value.id)
        _ = try await replaying("draft-moved.json", status: 202).post(.moveDraftToIMAP(id: created.data.value.id))
        _ = try await replaying("draft-deleted.json", status: 202).delete(.deleteDraft(id: created.data.value.id))
    }

    @Test("outbox list, enqueue, from-draft, update, send and delete")
    func outbox() async throws {
        let list = try await replaying("outbox.json").get(.outbox)
        #expect(list.data.messages.allSatisfy { $0.value.type == 0 })
        let created = try await replaying("outbox-created.json", status: 201).post(.enqueueMessage, body: draft)
        let id = created.data.value.id
        #expect(id > 0)
        let fetched = try await replaying("outbox-message.json").get(.outboxMessage(id: id))
        #expect(fetched.data.value.type == 0)
        let fromDraft = try await replaying("outbox-from-draft.json", status: 201)
            .post(.outboxFromDraft(draftId: 1), body: SendAtRequest(sendAt: 1))
        #expect(fromDraft.data.value.type == 0)
        _ = try await replaying("outbox-updated.json", status: 202).put(.updateOutboxMessage(id: id), body: draft)
        _ = try await replaying("outbox-sent.json", status: 202).post(.sendOutboxMessage(id: id))
        _ = try await replaying("outbox-deleted.json", status: 202).delete(.deleteOutboxMessage(id: id))
    }

    @Test("an attachment upload goes out as multipart and answers the record")
    func upload() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: try .fixture("attachment-uploaded.json", status: 201))
        let client = MailClient.testing(transport: transport)
        let form = MultipartForm(parts: [
            .file(name: "attachment", filename: "a.txt", contentType: "text/plain", data: Data("x".utf8))
        ])
        let attachment = try await client.upload(.uploadAttachment, multipart: form)
        #expect(attachment.id > 0)
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }
}

@Suite("v2 settings endpoints through the client")
struct SettingsEndpointReplayTests {
    @Test("tag create, update and delete")
    func tags() async throws {
        let created = try await replaying("tag-created.json")
            .post(.createTag, body: TagRequest(displayName: "t", color: "#000000"))
        let updated = try await replaying("tag-updated.json")
            .put(.updateTag(id: created.id), body: TagRequest(displayName: "u", color: "#000000"))
        #expect(updated.id == created.id)
        _ = try await replaying("tag-deleted.json").delete(.deleteTag(accountId: 1, tagId: created.id))
    }

    @Test("autocomplete, Contacts matches, and the two Contacts writes")
    func recipients() async throws {
        let recipients = try await replaying("autocomplete.json").get(.autoComplete(term: "a"))
        #expect(!recipients.isEmpty)
        _ = try await replaying("contact-autocomplete.json").get(.contactAutoComplete(term: "a"))
        _ = try await replaying("contact-match.json").get(.contactMatch(email: "a@example.com"))
        _ = try await replaying("contact-added-email.json")
            .put(.addMailToContact, body: ContactAddRequest(uid: "u", mail: "a@example.com"))
        _ = try await replaying("contact-created.json")
            .put(.newContactWithMail, body: ContactNewRequest(contactName: "n", mail: "a@example.com"))
    }

    @Test("a preference PUT echoes the value")
    func preference() async throws {
        let saved = try await replaying("preference-saved.json")
            .put(
                .setPreference(key: "sort-order"), body: PreferenceRequest(key: "sort-order", value: .string("newest")))
        #expect(saved.stringValue != nil)
    }

    @Test("internal addresses: list, add and remove")
    func internalAddresses() async throws {
        let list = try await replaying("internal-addresses.json").get(.internalAddresses)
        #expect(list.status == "success")
        _ = try await replaying("internal-address-created.json").put(
            .addInternalAddress(address: "example.org", type: "domain"))
        _ = try await replaying("internal-address-deleted.json")
            .delete(.removeInternalAddress(address: "example.org", type: "domain"))
    }

    @Test("trusted senders take the domain type")
    func trustedSenderDomain() async throws {
        _ = try await replaying("trusted-sender-added.json").put(.trustSender(email: "example.org", type: "domain"))
        _ = try await replaying("trusted-sender-removed.json").delete(
            .untrustSender(email: "example.org", type: "domain"))
    }

    @Test("with ManageSieve off, the Sieve and out-of-office routes are the server's 400")
    func sieveOff() async throws {
        let cases: [(String, (MailClient) async throws -> Void)] = [
            ("sieve-active.json", { _ = try await $0.get(.sieveScript(accountId: 1)) }),
            // PUT answers the identical 400 body (verified live); the GET's
            // recording stands in for it.
            (
                "sieve-active.json",
                { _ = try await $0.put(.updateSieveScript(accountId: 1), body: SieveScriptRequest(script: "#")) }
            ),
            ("out-of-office.json", { _ = try await $0.get(.outOfOffice(accountId: 1)) }),
            ("out-of-office-updated.json", { _ = try await $0.post(.updateOutOfOffice(accountId: 1)) }),
            ("out-of-office-follow-system.json", { _ = try await $0.post(.followSystemOutOfOffice(accountId: 1)) }),
        ]
        for (fixture, call) in cases {
            do {
                try await call(try await replaying(fixture, status: 400))
                Issue.record("expected a throw for \(fixture)")
            } catch MailError.server(let status, let message) {
                #expect(status == 400)
                #expect(message == "ManageSieve is disabled")
            }
        }
    }

    @Test("configuring Sieve answers the account's sieve state")
    func configureSieve() async throws {
        _ = try await replaying("sieve-account-updated.json").put(.configureSieve(accountId: 1))
    }

    @Test("with ManageSieve off, filters are an HTML 500 with no message")
    func filtersOff() async throws {
        for (fixture, call) in [
            ("error-filter-500.html", { (client: MailClient) in _ = try await client.get(.filters(accountId: 1)) }),
            (
                "error-filter-put-500.html",
                { (client: MailClient) in _ = try await client.put(.updateFilters(accountId: 1)) }
            ),
        ] as [(String, (MailClient) async throws -> Void)] {
            do {
                try await call(try await replaying(fixture, status: 500))
                Issue.record("expected a throw for \(fixture)")
            } catch MailError.server(let status, let message) {
                #expect(status == 500)
                #expect(message == nil)
            }
        }
    }

    @Test("follow-up check")
    func followUp() async throws {
        let check = try await replaying("follow-up-check.json")
            .post(.followUpCheck, body: FollowUpCheckRequest(messageIds: [1]))
        #expect(check.status == "success")
    }

    @Test("quick actions and their steps")
    func quickActions() async throws {
        let list = try await replaying("quick-actions.json").get(.quickActions)
        #expect(list.data.allSatisfy { $0.id > 0 })
        let created = try await replaying("quick-action-created.json")
            .post(.createQuickAction, body: QuickActionRequest(name: "q", accountId: 1))
        let renamed = try await replaying("quick-action-updated.json")
            .put(.renameQuickAction(id: created.data.id), body: QuickActionRequest(name: "r", accountId: nil))
        #expect(renamed.data.id == created.data.id)
        _ = try await replaying("quick-action-deleted.json").delete(.deleteQuickAction(id: created.data.id))

        let step = ActionStepRequest(name: "markAsRead", order: 1, actionId: created.data.id)
        let createdStep = try await replaying("action-step-created.json").post(.createActionStep, body: step)
        let updatedStep = try await replaying("action-step-updated.json")
            .put(.updateActionStep(id: createdStep.data.id), body: step)
        #expect(updatedStep.data.id == createdStep.data.id)
        _ = try await replaying("action-step-deleted.json").delete(.deleteActionStep(id: createdStep.data.id))
    }

    @Test("text blocks, their shares, and the shared-with-me list")
    func textBlocks() async throws {
        let list = try await replaying("text-blocks.json").get(.textBlocks)
        #expect(list.data.allSatisfy { $0.id > 0 })
        let block = TextBlockRequest(title: "t", content: "c")
        let created = try await replaying("text-block-created.json").post(.createTextBlock, body: block)
        let updated = try await replaying("text-block-updated.json").put(
            .updateTextBlock(id: created.data.id), body: block)
        #expect(updated.data.id == created.data.id)
        let shares = try await replaying("text-block-shares.json").get(.textBlockShares(textBlockId: created.data.id))
        #expect(shares.data.allSatisfy { $0.type == "user" || $0.type == "group" })
        let shared = try await replaying("text-block-shares-all.json").get(.sharedTextBlocks)
        #expect(shared.data.allSatisfy { $0.id > 0 })
        _ = try await replaying("text-block-share-created.json")
            .post(
                .shareTextBlock,
                body: TextBlockShareRequest(textBlockId: created.data.id, shareWith: "admin", type: "group"))
        _ = try await replaying("text-block-share-deleted.json")
            .delete(.unshareTextBlock(textBlockId: created.data.id, shareWith: "admin"))
        _ = try await replaying("text-block-deleted.json").delete(.deleteTextBlock(id: created.data.id))
    }

    @Test("S/MIME certificates: list, multipart import and delete")
    func smime() async throws {
        let list = try await replaying("smime-certificates.json").get(.smimeCertificates)
        #expect(list.data.allSatisfy { $0.id > 0 })
        let form = MultipartForm(parts: [
            .file(name: "certificate", filename: "c.pem", contentType: "application/x-pem-file", data: Data("x".utf8))
        ])
        let created = try await replaying("smime-certificate-created.json").upload(
            .uploadSmimeCertificate, multipart: form)
        #expect(created.data?.id ?? 0 > 0)
        _ = try await replaying("smime-certificate-deleted.json").delete(.deleteSmimeCertificate(id: 1))
    }
}

@Suite("Non-Mail OCS endpoints through the client")
struct OCSEndpointReplayTests {
    @Test("translation languages decode; translate without a provider is the OCS 412")
    func translation() async throws {
        let languages = try await replaying("translation-languages.json").get(.translationLanguages)
        #expect(languages.meta.statuscode == 200)
        let client = try await replaying("translation-translate.json", status: 412)
        do {
            _ = try await client.post(
                .translate, body: TranslateRequest(text: "Hallo", fromLanguage: nil, toLanguage: "en"))
            Issue.record("expected a throw")
        } catch MailError.server(let status, _) {
            #expect(status == 412)
        }
    }

    @Test("TaskProcessing task types, the llm_* flag source")
    func taskTypes() async throws {
        let types = try await replaying("taskprocessing-tasktypes.json").get(.taskTypes)
        #expect(types.meta.statuscode == 200)
        #expect(!types.data.isAvailable(TaskTypes.Known.summary) || types.data.types.count > 0)
    }

    @Test("Smart Picker providers and a provider search")
    func smartPicker() async throws {
        let providers = try await replaying("references-providers.json").get(.referenceProviders)
        #expect(!providers.data.isEmpty)
        let search = try await replaying("picker-search-files.json").get(.pickerSearch(providerId: "files", term: "a"))
        #expect(search.data.name != nil)
    }

    @Test("notifications on a server without the app is a 404, which the caller reads as absent")
    func notificationsAbsent() async throws {
        for call in [
            { (client: MailClient) in _ = try await client.get(.notifications) },
            { (client: MailClient) in _ = try await client.delete(.deleteNotification(id: 1)) },
        ] as [(MailClient) async throws -> Void] {
            do {
                try await call(try await replaying("notifications.json", status: 404))
                Issue.record("expected a throw")
            } catch MailError.notFound {
                // The absence signal: no notifications surface, nothing to show.
            }
        }
    }

    @Test("a created share link carries the public URL")
    func shareLink() async throws {
        let share = try await replaying("share-link-created.json")
            .post(.createShareLink, body: ShareLinkRequest(path: "/a.pdf"))
        #expect(share.data.shareType == 3)
        #expect(share.data.url != nil)
    }

    @Test("teams")
    func circles() async throws {
        let circles = try await replaying("circles.json").get(.circles)
        #expect(circles.data.allSatisfy { !$0.id.isEmpty })
    }
}

@Suite("v2 retryability")
struct V2RetryabilityTests {
    private static func entry<T>(_ endpoint: Endpoint<T>) -> (name: String, retryable: Bool) {
        (endpoint.name, endpoint.isRetryable)
    }

    /// Every v2 mutation. Sends, moves and creates are never retried by the
    /// client; the drainer owns replaying them.
    private static let mutations: [(name: String, retryable: Bool)] = [
        entry(.createAccount), entry(.updateAccount(id: 1)), entry(.patchAccount(id: 1)),
        entry(.deleteAccount(id: 1)), entry(.createAlias(accountId: 1)),
        entry(.grantDelegation(accountId: 1)), entry(.oauthState), entry(.createMailbox),
        entry(.patchMailbox(id: 1)), entry(.clearMailbox(id: 1)), entry(.repairMailbox(id: 1)),
        entry(.addMessageTag(messageId: 1, imapLabel: "$x")), entry(.snoozeThread(messageId: 1)),
        entry(.sendMDN(messageId: 1)), entry(.unsubscribe(messageId: 1)), entry(.createDraft),
        entry(.moveDraftToIMAP(id: 1)), entry(.enqueueMessage), entry(.sendOutboxMessage(id: 1)),
        entry(.uploadAttachment), entry(.createTag), entry(.setPreference(key: "k")),
        entry(.uploadSmimeCertificate), entry(.translate), entry(.createShareLink),
    ]

    @Test("no v2 mutation is retried by the client")
    func mutationsAreNotRetried() {
        for mutation in Self.mutations {
            #expect(!mutation.retryable, "\(mutation.name) must not auto-retry")
        }
    }

    @Test("the read dressed as a POST is the exception, and the connection test is not retried")
    func exceptions() {
        let check: Endpoint<JSONEnvelope<FollowUpCheck>> = .followUpCheck
        #expect(check.isRetryable)
        #expect(check.method == .post)
        let test: Endpoint<JSONEnvelope<Bool?>> = .testAccount(accountId: 1)
        #expect(!test.isRetryable)
    }
}
