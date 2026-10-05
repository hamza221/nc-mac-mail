// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore

// The non-Mail OCS routes the web client's integrations use. Each path here
// was confirmed against a live Nextcloud 36 before being written down — the
// verification notes are in docs/reference/api-payloads.md §Non-Mail OCS routes.

// MARK: - Translation

extension Endpoint where Response == OCSResponse<TranslationLanguages> {
    /// `GET /ocs/v2.php/translation/languages`. Exists even with no provider
    /// (verified live): an empty `languages` means the translate UI stays
    /// hidden, which is also how availability is discovered.
    public static var translationLanguages: Endpoint<OCSResponse<TranslationLanguages>> {
        Endpoint(
            name: "translationLanguages",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/translation/languages",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == OCSResponse<TranslationResult> {
    /// `POST /ocs/v2.php/translation/translate`. Body: `text`, nullable
    /// `fromLanguage`, `toLanguage`. OCS 412 with "No translation provider
    /// available" when there is none (verified live). Not retried: a failed
    /// translation is for the user to re-trigger, not the client to replay
    /// against a paid provider.
    public static var translate: Endpoint<OCSResponse<TranslationResult>> {
        Endpoint(
            name: "translate",
            method: .post,
            base: .server,
            encodedPath: "ocs/v2.php/translation/translate",
            isRetryable: false
        )
    }
}

extension Endpoint where Response == OCSResponse<TaskTypes> {
    /// `GET /ocs/v2.php/taskprocessing/tasktypes` — the providers the instance
    /// has, which is how the `llm_*` and `context_chat_available` flags are
    /// discovered (`docs/reference/server-flags.md`). `{"types":[]}` on a
    /// server with none (verified live).
    public static var taskTypes: Endpoint<OCSResponse<TaskTypes>> {
        Endpoint(
            name: "taskTypes",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/taskprocessing/tasktypes",
            isRetryable: true
        )
    }
}

// MARK: - Smart Picker

extension Endpoint where Response == OCSResponse<[ReferenceProvider]> {
    /// `GET /ocs/v2.php/references/providers` (verified live).
    public static var referenceProviders: Endpoint<OCSResponse<[ReferenceProvider]>> {
        Endpoint(
            name: "referenceProviders",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/references/providers",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == OCSResponse<UnifiedSearchResult> {
    /// `GET /ocs/v2.php/search/providers/{providerId}/search?term=` — what a
    /// picker provider's `search_providers_ids` point at (verified live).
    /// `cursor` is the previous result's cursor, echoed back verbatim.
    public static func pickerSearch(
        providerId: String,
        term: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> Endpoint<OCSResponse<UnifiedSearchResult>> {
        var query = [URLQueryItem(name: "term", value: term)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return Endpoint(
            name: "pickerSearch",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/search/providers/\(escape(providerId))/search",
            query: query,
            isRetryable: true
        )
    }
}

// MARK: - Notifications

extension Endpoint where Response == OCSResponse<[ServerNotification]> {
    /// `GET /ocs/v2.php/apps/notifications/api/v2/notifications`. On a server
    /// without the notifications app this is a 404 (observed live) — a normal
    /// condition the caller treats as "no notifications surface", not an error
    /// to show.
    public static var notifications: Endpoint<OCSResponse<[ServerNotification]>> {
        Endpoint(
            name: "notifications",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/apps/notifications/api/v2/notifications",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /ocs/v2.php/apps/notifications/api/v2/notifications/{id}` —
    /// dismisses one notification.
    public static func deleteNotification(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "deleteNotification",
            method: .delete,
            base: .server,
            encodedPath: "ocs/v2.php/apps/notifications/api/v2/notifications/\(id)",
            isRetryable: false
        )
    }
}

// MARK: - Share links

extension Endpoint where Response == OCSResponse<ShareLink> {
    /// `POST /ocs/v2.php/apps/files_sharing/api/v1/shares`. Body: `{"path":
    /// "/…", "shareType": 3}` creates the public link the composer pastes
    /// (verified live). A create — never retried.
    public static var createShareLink: Endpoint<OCSResponse<ShareLink>> {
        Endpoint(
            name: "createShareLink",
            method: .post,
            base: .server,
            encodedPath: "ocs/v2.php/apps/files_sharing/api/v1/shares",
            isRetryable: false
        )
    }
}

// MARK: - Teams (Circles)

extension Endpoint where Response == OCSResponse<[Circle]> {
    /// `GET /ocs/v2.php/apps/circles/circles` — the user's teams (verified
    /// live).
    public static var circles: Endpoint<OCSResponse<[Circle]>> {
        Endpoint(
            name: "circles",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/apps/circles/circles",
            isRetryable: true
        )
    }
}
