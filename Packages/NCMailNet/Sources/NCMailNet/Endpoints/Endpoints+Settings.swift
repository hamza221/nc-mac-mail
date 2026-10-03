// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore

// Tags, recipient autocomplete, preferences, internal addresses, Sieve,
// out-of-office, follow-up, quick actions, text blocks, S/MIME certificates —
// the settings surface. Trusted senders live in `Endpoints.swift` (v1).

// MARK: - Tags

extension Endpoint where Response == Tag {
    /// `POST /api/tags`. Body: `displayName`, `color`. Answers the bare tag
    /// (verified live): the server derives `imapLabel` from the name.
    public static var createTag: Endpoint<Tag> {
        Endpoint(name: "createTag", method: .post, encodedPath: "tags", isRetryable: false)
    }

    /// `PUT /api/tags/{id}` — rename or recolour.
    public static func updateTag(id: Int) -> Endpoint<Tag> {
        Endpoint(name: "updateTag", method: .put, encodedPath: "tags/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/tags/{accountId}/delete/{id}` — removes the tag from one
    /// account. Answers `[id]` (verified live), nothing to read.
    public static func deleteTag(accountId: Int, tagId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "deleteTag",
            method: .delete,
            encodedPath: "tags/\(accountId)/delete/\(tagId)",
            isRetryable: false
        )
    }
}

// MARK: - Recipient autocomplete

extension Endpoint where Response == [AutocompleteRecipient] {
    /// `GET /api/autoComplete?term=` — contacts, collected addresses, users,
    /// groups and circles, as a bare array (verified live).
    public static func autoComplete(term: String) -> Endpoint<[AutocompleteRecipient]> {
        Endpoint(
            name: "autoComplete",
            method: .get,
            encodedPath: "autoComplete",
            query: [URLQueryItem(name: "term", value: term)],
            isRetryable: true
        )
    }
}

extension Endpoint where Response == [ContactMatch] {
    /// `GET /api/contactIntegration/autoComplete/{term}` — Contacts-app matches.
    public static func contactAutoComplete(term: String) -> Endpoint<[ContactMatch]> {
        Endpoint(
            name: "contactAutoComplete",
            method: .get,
            encodedPath: "contactIntegration/autoComplete/\(escape(term))",
            isRetryable: true
        )
    }

    /// `GET /api/contactIntegration/match/{mail}` — the contact behind an
    /// address.
    public static func contactMatch(email: String) -> Endpoint<[ContactMatch]> {
        Endpoint(
            name: "contactMatch",
            method: .get,
            encodedPath: "contactIntegration/match/\(escape(email))",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `PUT /api/contactIntegration/add` — adds an address to an existing
    /// contact. Body: `{"uid": …, "mail": …}`.
    public static var addMailToContact: Endpoint<EmptyResponse> {
        Endpoint(name: "addMailToContact", method: .put, encodedPath: "contactIntegration/add", isRetryable: false)
    }

    /// `PUT /api/contactIntegration/new` — creates a contact. Body:
    /// `{"contactName": …, "mail": …}`.
    public static var newContactWithMail: Endpoint<EmptyResponse> {
        Endpoint(name: "newContactWithMail", method: .put, encodedPath: "contactIntegration/new", isRetryable: false)
    }
}

// MARK: - Preferences

extension Endpoint where Response == Preference {
    /// `PUT /api/preferences/{key}`. Body: `{"key": …, "value": …}` — yes, the
    /// key goes in both places. Echoes `{"value": …}` back (verified live).
    public static func setPreference(key: String) -> Endpoint<Preference> {
        Endpoint(
            name: "setPreference",
            method: .put,
            encodedPath: "preferences/\(escape(key))",
            isRetryable: false
        )
    }
}

// MARK: - Internal addresses

extension Endpoint where Response == JSONEnvelope<[InternalAddress]> {
    /// `GET /api/internalAddress` — `{"status":"success","data":[…]}`
    /// (verified live, empty).
    public static var internalAddresses: Endpoint<JSONEnvelope<[InternalAddress]>> {
        Endpoint(name: "internalAddresses", method: .get, encodedPath: "internalAddress", isRetryable: true)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `PUT /api/internalAddress/{address}?type=` — `individual` or `domain`.
    public static func addInternalAddress(address: String, type: String = "individual") -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "addInternalAddress",
            method: .put,
            encodedPath: "internalAddress/\(escape(address))",
            query: [URLQueryItem(name: "type", value: type)],
            isRetryable: false
        )
    }

    /// `DELETE /api/internalAddress/{address}?type=`.
    public static func removeInternalAddress(address: String, type: String = "individual") -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "removeInternalAddress",
            method: .delete,
            encodedPath: "internalAddress/\(escape(address))",
            query: [URLQueryItem(name: "type", value: type)],
            isRetryable: false
        )
    }
}

// MARK: - Sieve

extension Endpoint where Response == EmptyResponse {
    /// `PUT /api/sieve/account/{id}` — configures the ManageSieve connection.
    public static func configureSieve(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "configureSieve", method: .put, encodedPath: "sieve/account/\(accountId)", isRetryable: false)
    }

    /// `PUT /api/sieve/active/{id}` — replaces the active script. Body:
    /// `{"script": …}`.
    public static func updateSieveScript(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "updateSieveScript",
            method: .put,
            encodedPath: "sieve/active/\(accountId)",
            isRetryable: false
        )
    }
}

extension Endpoint where Response == JSONEnvelope<SieveScript?> {
    /// `GET /api/sieve/active/{id}`. With ManageSieve disabled this is a 400
    /// `ClientException` ("ManageSieve is disabled"), surfaced as `MailError`.
    public static func sieveScript(accountId: Int) -> Endpoint<JSONEnvelope<SieveScript?>> {
        Endpoint(name: "sieveScript", method: .get, encodedPath: "sieve/active/\(accountId)", isRetryable: true)
    }
}

// MARK: - Mail filters

extension Endpoint where Response == JSONEnvelope<[MailFilter]?> {
    /// `GET /api/filter/{accountId}` — the filters parsed out of the managed
    /// Sieve section. With ManageSieve disabled this answers **HTTP 500 with an
    /// empty body** (observed live, Mail 5.12).
    public static func filters(accountId: Int) -> Endpoint<JSONEnvelope<[MailFilter]?>> {
        Endpoint(name: "filters", method: .get, encodedPath: "filter/\(accountId)", isRetryable: true)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `PUT /api/filter/{accountId}` — replaces the filters and regenerates
    /// the script. Body: `{"filters": […]}`.
    public static func updateFilters(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "updateFilters", method: .put, encodedPath: "filter/\(accountId)", isRetryable: false)
    }
}

// MARK: - Out of office

extension Endpoint where Response == JSONEnvelope<OutOfOfficeState?> {
    /// `GET /api/out-of-office/{accountId}`. Same ManageSieve 400 as
    /// ``sieveScript(accountId:)`` when Sieve is off.
    public static func outOfOffice(accountId: Int) -> Endpoint<JSONEnvelope<OutOfOfficeState?>> {
        Endpoint(name: "outOfOffice", method: .get, encodedPath: "out-of-office/\(accountId)", isRetryable: true)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `POST /api/out-of-office/{accountId}`. Body: `enabled`, nullable
    /// `start`/`end`, `subject`, `message`.
    public static func updateOutOfOffice(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "updateOutOfOffice",
            method: .post,
            encodedPath: "out-of-office/\(accountId)",
            isRetryable: false
        )
    }

    /// `POST /api/out-of-office/{accountId}/follow-system` — follow the
    /// Nextcloud absence setting instead of a Sieve-managed one.
    public static func followSystemOutOfOffice(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "followSystemOutOfOffice",
            method: .post,
            encodedPath: "out-of-office/\(accountId)/follow-system",
            isRetryable: false
        )
    }
}

// MARK: - Follow-up reminders

extension Endpoint where Response == JSONEnvelope<FollowUpCheck> {
    /// `POST /api/follow-up/check-message-ids`. Body: `{"messageIds": […]}`.
    /// A read dressed as a POST — it changes nothing server-side — so it is
    /// retryable, like sync.
    public static var followUpCheck: Endpoint<JSONEnvelope<FollowUpCheck>> {
        Endpoint(
            name: "followUpCheck",
            method: .post,
            encodedPath: "follow-up/check-message-ids",
            isRetryable: true
        )
    }
}

// MARK: - Quick actions

extension Endpoint where Response == JSONEnvelope<[QuickAction]> {
    /// `GET /api/quick-actions` (verified live).
    public static var quickActions: Endpoint<JSONEnvelope<[QuickAction]>> {
        Endpoint(name: "quickActions", method: .get, encodedPath: "quick-actions", isRetryable: true)
    }
}

extension Endpoint where Response == JSONEnvelope<QuickAction> {
    /// `POST /api/quick-actions`. Body: `{"name": …, "accountId": …}`.
    public static var createQuickAction: Endpoint<JSONEnvelope<QuickAction>> {
        Endpoint(name: "createQuickAction", method: .post, encodedPath: "quick-actions", isRetryable: false)
    }

    /// `PUT /api/quick-actions/{id}` — rename. Body: `{"name": …}`.
    public static func renameQuickAction(id: Int) -> Endpoint<JSONEnvelope<QuickAction>> {
        Endpoint(name: "renameQuickAction", method: .put, encodedPath: "quick-actions/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/quick-actions/{id}`.
    public static func deleteQuickAction(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteQuickAction", method: .delete, encodedPath: "quick-actions/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == JSONEnvelope<ActionStep> {
    /// `POST /api/action-step`. Body: `name`, `order`, `actionId`, plus
    /// `tagId` for `applyTag` and `mailboxId` for `moveThread`.
    public static var createActionStep: Endpoint<JSONEnvelope<ActionStep>> {
        Endpoint(name: "createActionStep", method: .post, encodedPath: "action-step", isRetryable: false)
    }

    /// `PUT /api/action-step/{id}`.
    public static func updateActionStep(id: Int) -> Endpoint<JSONEnvelope<ActionStep>> {
        Endpoint(name: "updateActionStep", method: .put, encodedPath: "action-step/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/action-step/{id}`.
    public static func deleteActionStep(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteActionStep", method: .delete, encodedPath: "action-step/\(id)", isRetryable: false)
    }
}

// MARK: - Text blocks

extension Endpoint where Response == JSONEnvelope<[TextBlock]> {
    /// `GET /api/textBlocks` — the user's own and the ones shared with them.
    public static var textBlocks: Endpoint<JSONEnvelope<[TextBlock]>> {
        Endpoint(name: "textBlocks", method: .get, encodedPath: "textBlocks", isRetryable: true)
    }

    /// `GET /api/textBlockshares` — the blocks *other users* shared with this
    /// one, as text blocks rather than share records (verified live). The
    /// lowercase `s` is the server's spelling, not a typo here.
    public static var sharedTextBlocks: Endpoint<JSONEnvelope<[TextBlock]>> {
        Endpoint(name: "sharedTextBlocks", method: .get, encodedPath: "textBlockshares", isRetryable: true)
    }
}

extension Endpoint where Response == JSONEnvelope<TextBlock> {
    /// `POST /api/textBlocks`. Body: `{"title": …, "content": …}`.
    public static var createTextBlock: Endpoint<JSONEnvelope<TextBlock>> {
        Endpoint(name: "createTextBlock", method: .post, encodedPath: "textBlocks", isRetryable: false)
    }

    /// `PUT /api/textBlocks/{id}`.
    public static func updateTextBlock(id: Int) -> Endpoint<JSONEnvelope<TextBlock>> {
        Endpoint(name: "updateTextBlock", method: .put, encodedPath: "textBlocks/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/textBlocks/{id}`.
    public static func deleteTextBlock(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteTextBlock", method: .delete, encodedPath: "textBlocks/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == JSONEnvelope<[TextBlockShare]> {
    /// `GET /api/textBlocks/{id}/shares` — the shares of one block.
    public static func textBlockShares(textBlockId: Int) -> Endpoint<JSONEnvelope<[TextBlockShare]>> {
        Endpoint(
            name: "textBlockShares",
            method: .get,
            encodedPath: "textBlocks/\(textBlockId)/shares",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `POST /api/textBlockshares`. Body: `textBlockId`, `shareWith`, `type`
    /// (`user` or `group`).
    public static var shareTextBlock: Endpoint<EmptyResponse> {
        Endpoint(name: "shareTextBlock", method: .post, encodedPath: "textBlockshares", isRetryable: false)
    }

    /// `DELETE /api/textBlockshares/{id}?shareWith=`.
    public static func unshareTextBlock(textBlockId: Int, shareWith: String) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "unshareTextBlock",
            method: .delete,
            encodedPath: "textBlockshares/\(textBlockId)",
            query: [URLQueryItem(name: "shareWith", value: shareWith)],
            isRetryable: false
        )
    }
}

// MARK: - S/MIME certificates

extension Endpoint where Response == JSONEnvelope<[SmimeCertificate]> {
    /// `GET /api/smime/certificates` (verified live, empty).
    public static var smimeCertificates: Endpoint<JSONEnvelope<[SmimeCertificate]>> {
        Endpoint(name: "smimeCertificates", method: .get, encodedPath: "smime/certificates", isRetryable: true)
    }
}

extension Endpoint where Response == JSONEnvelope<SmimeCertificate?> {
    /// `POST /api/smime/certificates` — multipart, fields `certificate`
    /// (required) and `privateKey` (optional), both PEM: PKCS#12 is converted
    /// client-side because the server cannot decrypt it. Goes through
    /// ``MailClient/upload(_:multipart:)``.
    public static var uploadSmimeCertificate: Endpoint<JSONEnvelope<SmimeCertificate?>> {
        Endpoint(name: "uploadSmimeCertificate", method: .post, encodedPath: "smime/certificates", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/smime/certificates/{id}`.
    public static func deleteSmimeCertificate(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "deleteSmimeCertificate",
            method: .delete,
            encodedPath: "smime/certificates/\(id)",
            isRetryable: false
        )
    }
}
