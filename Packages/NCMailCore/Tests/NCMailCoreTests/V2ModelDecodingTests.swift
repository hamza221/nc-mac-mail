// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailCore

// One decode test per v2 model, each against a fixture the recorder wrote.
//
// Fixtures are re-recorded per run and the dev server's content shifts with
// every recording (the recorder sends mail to itself and cycles scratch
// objects), so these assert structure and types, never counts or text.

@Suite("v2 envelopes")
struct JSONEnvelopeDecodingTests {
    @Test("the quota payload sits inside the success envelope")
    func decodesQuota() throws {
        let quota = try Fixture.decode(JSONEnvelope<Quota>.self, from: "account-quota.json")
        #expect(quota.status == "success")
        #expect(quota.data.usage >= 0)
        #expect(quota.data.limit >= 0)
    }

    @Test("the connection test answers data with no status at all")
    func decodesAccountTest() throws {
        let result = try Fixture.decode(JSONEnvelope<Bool?>.self, from: "account-test.json")
        #expect(result.status == nil)
        #expect(result.data == true)
    }

    @Test("a 204 body synthesises through EmptyBodyRepresentable")
    func synthesisesEmptyBody() throws {
        // thread-summary.json is a recorded 204: zero bytes. JSONDecoder cannot
        // touch it; the conformance builds the "nothing there" value instead.
        let recorded = try Fixture.data("thread-summary.json")
        #expect(recorded.isEmpty)
        let summary = ThreadSummaryResponse()
        #expect(summary.data == nil)
        let reply = SmartReplyResponse()
        #expect(reply.data == nil)
    }

    @Test("eventdata sends an explicit null when there is nothing to suggest")
    func decodesNullEventData() throws {
        let event = try Fixture.decode(JSONEnvelope<EventData?>.self, from: "thread-eventdata.json")
        #expect(event.data == nil)
    }

    @Test("a sieve route on a sieve-less server decodes as the fail envelope")
    func decodesSieveFailureEnvelope() throws {
        // The live server has ManageSieve off, so the honest recording is
        // `{"status":"fail","data":{"message":…,"type":…}}`. The lenient
        // payload decodes it with every field nil; MailClient would have turned
        // the 400 into a MailError before decoding anyway.
        let scripted = try Fixture.decode(JSONEnvelope<SieveScript?>.self, from: "sieve-active.json")
        #expect(scripted.status == "fail")
        #expect(scripted.data?.script == nil)
        let state = try Fixture.decode(JSONEnvelope<OutOfOfficeState?>.self, from: "out-of-office.json")
        #expect(state.status == "fail")
    }
}

@Suite("v2 account models")
struct AccountSurfaceDecodingTests {
    @Test("a PATCH answers the bare account JSON")
    func decodesPatchedAccount() throws {
        let account = try Fixture.decode(RawBacked<Account>.self, from: "account-patch.json")
        #expect(account.value.id > 0)
        #expect(!account.value.emailAddress.isEmpty)
    }

    @Test("aliases decode from the list and from the create echo")
    func decodesAliases() throws {
        for alias in try Fixture.decode([Alias].self, from: "aliases.json") {
            #expect(alias.id > 0)
            #expect(alias.alias.contains("@"))
        }
        let created = try Fixture.decode(Alias.self, from: "alias-created.json")
        #expect(created.id > 0)
        // Fresh alias: null signature and null signatureMode, both tolerated.
        #expect(created.signature == nil)
        #expect(!created.provisioned)
    }

    @Test("the ISPDB lookup carries both server halves")
    func decodesISPDB() throws {
        let result = try Fixture.decode(JSONEnvelope<AutoconfigResult?>.self, from: "autoconfig-ispdb.json")
        let config = try #require(result.data)
        let imap = try #require(config.imapConfig)
        #expect(!imap.host.isEmpty)
        #expect(imap.port > 0)
        #expect(config.smtpConfig != nil)
    }

    @Test("the MX lookup is a bare list of hosts in the envelope")
    func decodesMX() throws {
        let result = try Fixture.decode(JSONEnvelope<[String]?>.self, from: "autoconfig-mx.json")
        let hosts = try #require(result.data)
        #expect(!hosts.isEmpty)
    }

    @Test("the port probe answers a boolean")
    func decodesAutoconfigTest() throws {
        let result = try Fixture.decode(JSONEnvelope<Bool?>.self, from: "autoconfig-test.json")
        #expect(result.data != nil)
    }

    @Test("delegations: the list and the grant echo share one element shape")
    func decodesDelegations() throws {
        let delegates = try Fixture.decode([AccountDelegate].self, from: "delegations.json")
        for delegate in delegates {
            #expect(delegate.id > 0)
            #expect(!delegate.userId.isEmpty)
        }
        let granted = try Fixture.decode(AccountDelegate.self, from: "delegation-created.json")
        #expect(granted.id > 0)
        #expect(granted.accountId > 0)
        #expect(!granted.userId.isEmpty)
    }

    @Test("the OAuth state mint answers a signed token")
    func decodesOAuthState() throws {
        let state = try Fixture.decode(JSONEnvelope<OAuthState>.self, from: "oauth-state.json")
        #expect(!state.data.state.isEmpty)
    }

    @Test("the OCS account list is the trimmed shape, not the account payload")
    func decodesOCSAccountList() throws {
        let list = try Fixture.decode(OCSResponse<[AccountSummary]>.self, from: "ocs-account-list.json")
        let account = try #require(list.data.first)
        #expect(account.id > 0)
        #expect(!account.isDelegated)
        // The aliases are trimmed as well: `email`, not the `alias` key.
        for alias in account.aliases {
            #expect(alias.id > 0)
            #expect(alias.email?.contains("@") == true)
        }
    }
}

@Suite("v2 mailbox and message models")
struct MessageSurfaceDecodingTests {
    @Test("a created mailbox answers the mailbox JSON with the integer role")
    func decodesCreatedMailbox() throws {
        let mailbox = try Fixture.decode(RawBacked<Mailbox>.self, from: "mailbox-created.json")
        #expect(mailbox.value.id > 0)
        // A scratch folder has no special use, which arrives as the integer 0.
        #expect(mailbox.value.specialRole == nil)
    }

    @Test("the raw source is JSON around an RFC 822 string")
    func decodesSource() throws {
        let source = try Fixture.decode(MessageSource.self, from: "message-source.json")
        #expect(!source.source.isEmpty)
    }

    @Test("dkim answers a bare valid flag")
    func decodesDkim() throws {
        _ = try Fixture.decode(DkimResult.self, from: "message-dkim.json")
    }

    @Test("itineraries are a bare array kept as raw JSON")
    func decodesItineraries() throws {
        let itineraries = try Fixture.decode([AnyJSON].self, from: "message-itineraries.json")
        // Empty on the dev server — KItinerary found nothing to extract.
        #expect(itineraries.isEmpty)
    }
}

@Suite("v2 compose models")
struct ComposeDecodingTests {
    @Test("a created draft is a LocalMessage of type draft")
    func decodesCreatedDraft() throws {
        let draft = try Fixture.decode(
            JSONEnvelope<RawBacked<LocalMessage>>.self,
            from: "draft-created.json"
        ).data.value
        #expect(draft.id > 0)
        #expect(draft.type == 1, "TYPE_DRAFT")
        #expect(!draft.failed)
    }

    @Test("the outbox wraps its messages one level deeper")
    func decodesOutbox() throws {
        let outbox = try Fixture.decode(JSONEnvelope<OutboxMessages>.self, from: "outbox.json")
        for message in outbox.data.messages {
            #expect(message.value.id > 0)
            #expect(message.value.type == 0, "TYPE_OUTGOING")
        }
    }

    @Test("an uploaded attachment is the bare local record with an integer id")
    func decodesUploadedAttachment() throws {
        let attachment = try Fixture.decode(LocalAttachment.self, from: "attachment-uploaded.json")
        #expect(attachment.id > 0)
        #expect(attachment.fileName != nil)
    }
}

@Suite("v2 settings models")
struct SettingsDecodingTests {
    @Test("a created tag echoes back bare, with the derived IMAP label")
    func decodesCreatedTag() throws {
        let tag = try Fixture.decode(NCMailCore.Tag.self, from: "tag-created.json")
        #expect(tag.id > 0)
        #expect(tag.imapLabel.hasPrefix("$"))
    }

    @Test("autocomplete entries carry a single email string")
    func decodesAutocomplete() throws {
        let recipients = try Fixture.decode([AutocompleteRecipient].self, from: "autocomplete.json")
        #expect(!recipients.isEmpty)
        #expect(recipients.allSatisfy { $0.email != nil })
    }

    @Test("contact integration entries carry an email array instead")
    func decodesContactMatches() throws {
        let matches = try Fixture.decode([ContactMatch].self, from: "contact-autocomplete.json")
        #expect(matches.contains { !$0.email.isEmpty })
        _ = try Fixture.decode([ContactMatch].self, from: "contact-match.json")
    }

    @Test("internal addresses use the success envelope")
    func decodesInternalAddresses() throws {
        let list = try Fixture.decode(JSONEnvelope<[InternalAddress]>.self, from: "internal-addresses.json")
        #expect(list.status == "success")
    }

    @Test("a follow-up check answers the replied subset")
    func decodesFollowUpCheck() throws {
        let check = try Fixture.decode(JSONEnvelope<FollowUpCheck>.self, from: "follow-up-check.json")
        #expect(check.data.wasFollowedUp.allSatisfy { $0 > 0 })
    }

    @Test("quick actions nest their steps")
    func decodesQuickActions() throws {
        let actions = try Fixture.decode(JSONEnvelope<[QuickAction]>.self, from: "quick-actions.json")
        for action in actions.data {
            #expect(action.id > 0)
            for step in action.actionSteps {
                #expect(step.id > 0)
                #expect(step.name != nil)
            }
        }
        let created = try Fixture.decode(JSONEnvelope<QuickAction>.self, from: "quick-action-created.json")
        #expect(created.data.id > 0)
        let step = try Fixture.decode(JSONEnvelope<ActionStep>.self, from: "action-step-created.json")
        #expect(step.data.id > 0)
    }

    @Test("text blocks and their shares decode; the all-shares route answers blocks")
    func decodesTextBlocks() throws {
        let blocks = try Fixture.decode(JSONEnvelope<[TextBlock]>.self, from: "text-blocks.json")
        for block in blocks.data {
            #expect(block.id > 0)
        }
        let shares = try Fixture.decode(JSONEnvelope<[TextBlockShare]>.self, from: "text-block-shares.json")
        for share in shares.data {
            #expect(share.type == "user" || share.type == "group")
        }
        // The lowercase-s route answers the shared *blocks*, not share records.
        _ = try Fixture.decode(JSONEnvelope<[TextBlock]>.self, from: "text-block-shares-all.json")
    }

    @Test("certificates carry their parsed metadata in a nested info object")
    func decodesSmimeCertificates() throws {
        let list = try Fixture.decode(JSONEnvelope<[SmimeCertificate]>.self, from: "smime-certificates.json")
        let certificate = try #require(list.data.first)
        #expect(certificate.id > 0)
        #expect(certificate.hasKey)
        let info = try #require(certificate.info)
        #expect(info.notAfter ?? 0 > 0)
        #expect(info.purposes?.sign == true)
        let created = try Fixture.decode(
            JSONEnvelope<SmimeCertificate?>.self,
            from: "smime-certificate-created.json"
        )
        #expect(created.data?.id ?? 0 > 0)
    }

    @Test("a preference PUT echoes the value shape the GET uses")
    func decodesSavedPreference() throws {
        let preference = try Fixture.decode(Preference.self, from: "preference-saved.json")
        #expect(preference.stringValue != nil)
    }
}

@Suite("Non-Mail OCS models")
struct OCSDecodingTests {
    @Test("translation languages exist even with no provider")
    func decodesTranslationLanguages() throws {
        let languages = try Fixture.decode(OCSResponse<TranslationLanguages>.self, from: "translation-languages.json")
        #expect(languages.meta.statuscode == 200)
        // No provider on the dev server: the empty list *is* the availability
        // signal the translate UI reads.
        #expect(languages.data.languages.isEmpty)
        #expect(!languages.data.languageDetection)
    }

    @Test("translate without a provider is an OCS 412, decodable all the same")
    func decodesTranslateFailure() throws {
        let result = try Fixture.decode(OCSResponse<TranslationResult>.self, from: "translation-translate.json")
        #expect(result.meta.statuscode == 412)
        #expect(result.data.text == nil)
    }

    @Test("task types: PHP's empty map arrives as [] and reads as nothing available")
    func decodesTaskTypes() throws {
        let types = try Fixture.decode(OCSResponse<TaskTypes>.self, from: "taskprocessing-tasktypes.json")
        #expect(types.meta.statuscode == 200)
        // Whatever the instance has, an id it lacks is not available.
        #expect(!types.data.isAvailable("ncmail:not-a-task-type"))
    }

    @Test("the dav capability carries the system out-of-office flag")
    func decodesAbsenceCapability() throws {
        let response = try Fixture.decode(OCSResponse<Capabilities>.self, from: "capabilities.json")
        // Present on the recording instance; absent (so nil) where the admin
        // hid absence settings.
        _ = try #require(response.data.dav)
    }

    @Test("reference providers decode with their search provider ids")
    func decodesReferenceProviders() throws {
        let providers = try Fixture.decode(OCSResponse<[ReferenceProvider]>.self, from: "references-providers.json")
        #expect(!providers.data.isEmpty)
        #expect(providers.data.allSatisfy { !$0.id.isEmpty })
        #expect(providers.data.contains { !$0.searchProviderIds.isEmpty })
    }

    @Test("a picker search answers one provider's paginated result")
    func decodesPickerSearch() throws {
        let result = try Fixture.decode(OCSResponse<UnifiedSearchResult>.self, from: "picker-search-files.json")
        #expect(result.data.name != nil)
        for entry in result.data.entries {
            #expect(entry.title != nil)
        }
    }

    @Test("a server without the notifications app answers OCS failure, not JSON soup")
    func decodesNotificationsAbsence() throws {
        let notifications = try Fixture.decode(
            OCSResponse<[ServerNotification]>.self,
            from: "notifications.json"
        )
        // The dev server has no notifications app; the recorded body is the
        // honest OCS 998 failure with an empty data array.
        #expect(notifications.meta.status == "failure")
        #expect(notifications.data.isEmpty)
    }

    @Test("a created share link carries the string id and the public URL")
    func decodesShareLink() throws {
        let share = try Fixture.decode(OCSResponse<ShareLink>.self, from: "share-link-created.json")
        #expect(!share.data.id.isEmpty)
        #expect(share.data.shareType == 3)
        #expect(share.data.url != nil)
    }

    @Test("teams decode from the circles route")
    func decodesCircles() throws {
        let circles = try Fixture.decode(OCSResponse<[Circle]>.self, from: "circles.json")
        #expect(circles.data.allSatisfy { !$0.id.isEmpty })
    }
}
