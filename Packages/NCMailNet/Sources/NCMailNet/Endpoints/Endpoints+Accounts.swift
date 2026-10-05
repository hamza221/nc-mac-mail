// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore

// Account management, aliases, autoconfig, delegation and the OAuth state
// mint — the WS-16 account surface. URL escaping policy as in `Endpoints.swift`.

// MARK: - Accounts CRUD

extension Endpoint where Response == JSONEnvelope<RawBacked<Account>> {
    /// `POST /api/accounts` — HTTP 201 with the account inside the success
    /// envelope (`AccountsController::create` → `MailJsonResponse::success`,
    /// read from the live server's source; not recorded, because creating an
    /// account needs a second real mailbox). A connection failure is the fail
    /// envelope with `{"error": …, "service": "IMAP"|"SMTP", …}`; an admin who
    /// switched off new accounts gets the error envelope "Could not create
    /// account".
    public static var createAccount: Endpoint<JSONEnvelope<RawBacked<Account>>> {
        Endpoint(name: "createAccount", method: .post, encodedPath: "accounts", isRetryable: false)
    }

    /// `PUT /api/accounts/{id}` — replaces the server settings. Same envelope
    /// as create, unlike PATCH (`AccountsController::update`).
    public static func updateAccount(id: Int) -> Endpoint<JSONEnvelope<RawBacked<Account>>> {
        Endpoint(name: "updateAccount", method: .put, encodedPath: "accounts/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == RawBacked<Account> {
    /// `PATCH /api/accounts/{id}` — only the parameters sent are changed.
    /// Answers the bare account JSON, no envelope (verified live).
    public static func patchAccount(id: Int) -> Endpoint<RawBacked<Account>> {
        Endpoint(name: "patchAccount", method: .patch, encodedPath: "accounts/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/accounts/{id}` — the account and its cached data.
    public static func deleteAccount(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteAccount", method: .delete, encodedPath: "accounts/\(id)", isRetryable: false)
    }

    /// `PUT /api/accounts/{id}/signature`. Body: `{"signature": null}` clears.
    /// Answers a bare `[]` (verified live), which `EmptyResponse` swallows.
    public static func setAccountSignature(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "setAccountSignature",
            method: .put,
            encodedPath: "accounts/\(accountId)/signature",
            isRetryable: false
        )
    }

    /// `PUT /api/accounts/{id}/smime-certificate`. Null unlinks. Answers
    /// `{"status":"success","data":null}` (verified live).
    public static func setAccountSmimeCertificate(accountId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "setAccountSmimeCertificate",
            method: .put,
            encodedPath: "accounts/\(accountId)/smime-certificate",
            isRetryable: false
        )
    }
}

// MARK: - Quota and connectivity

extension Endpoint where Response == JSONEnvelope<Quota> {
    /// `GET /api/accounts/{id}/quota`.
    public static func quota(accountId: Int) -> Endpoint<JSONEnvelope<Quota>> {
        Endpoint(name: "quota", method: .get, encodedPath: "accounts/\(accountId)/quota", isRetryable: true)
    }
}

extension Endpoint where Response == JSONEnvelope<Bool?> {
    /// `GET /api/accounts/{id}/test` — a live IMAP and SMTP connection test.
    /// Answers `{"data":true}` with no status (verified live). A read, but
    /// **not retryable**: the result is the diagnostic, and silently retrying
    /// masks the flakiness the user asked about.
    public static func testAccount(accountId: Int) -> Endpoint<JSONEnvelope<Bool?>> {
        Endpoint(name: "testAccount", method: .get, encodedPath: "accounts/\(accountId)/test", isRetryable: false)
    }
}

// MARK: - Aliases

extension Endpoint where Response == [Alias] {
    /// `GET /api/accounts/{accountId}/aliases`.
    public static func aliases(accountId: Int) -> Endpoint<[Alias]> {
        Endpoint(name: "aliases", method: .get, encodedPath: "accounts/\(accountId)/aliases", isRetryable: true)
    }
}

extension Endpoint where Response == Alias {
    /// `POST /api/accounts/{accountId}/aliases`. Answers the created alias,
    /// bare, HTTP 201 (verified live).
    public static func createAlias(accountId: Int) -> Endpoint<Alias> {
        Endpoint(name: "createAlias", method: .post, encodedPath: "accounts/\(accountId)/aliases", isRetryable: false)
    }

    /// `PUT /api/accounts/{accountId}/aliases/{id}`.
    public static func updateAlias(accountId: Int, aliasId: Int) -> Endpoint<Alias> {
        Endpoint(
            name: "updateAlias",
            method: .put,
            encodedPath: "accounts/\(accountId)/aliases/\(aliasId)",
            isRetryable: false
        )
    }

    /// `DELETE /api/accounts/{accountId}/aliases/{id}` — answers the deleted
    /// alias (verified live).
    public static func deleteAlias(accountId: Int, aliasId: Int) -> Endpoint<Alias> {
        Endpoint(
            name: "deleteAlias",
            method: .delete,
            encodedPath: "accounts/\(accountId)/aliases/\(aliasId)",
            isRetryable: false
        )
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `PUT /api/accounts/{accountId}/aliases/{id}/signature`. Null clears.
    public static func setAliasSignature(accountId: Int, aliasId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "setAliasSignature",
            method: .put,
            encodedPath: "accounts/\(accountId)/aliases/\(aliasId)/signature",
            isRetryable: false
        )
    }
}

// MARK: - Auto configuration

// All three rate limited server-side (ispdb and mx 5/60 s, test 30/60 s);
// a 429 obeys Retry-After like everywhere else.

extension Endpoint where Response == JSONEnvelope<AutoconfigResult?> {
    /// `GET /api/autoconfig/ispdb/{host}/{email}` — the Mozilla ISPDB lookup.
    public static func autoconfigISPDB(host: String, email: String) -> Endpoint<JSONEnvelope<AutoconfigResult?>> {
        Endpoint(
            name: "autoconfigIspdb",
            method: .get,
            encodedPath: "autoconfig/ispdb/\(escape(host))/\(escape(email))",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == JSONEnvelope<[String]?> {
    /// `GET /api/autoconfig/mx/{email}` — MX-derived host guesses, e.g.
    /// `{"data":["mail.example.com","example.com"]}` (verified live).
    public static func autoconfigMX(email: String) -> Endpoint<JSONEnvelope<[String]?>> {
        Endpoint(
            name: "autoconfigMx",
            method: .get,
            encodedPath: "autoconfig/mx/\(escape(email))",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == JSONEnvelope<Bool?> {
    /// `GET /api/autoconfig/test?host=&port=` — does the port accept a
    /// connection. `{"status":"success","data":true}` (verified live).
    public static func autoconfigTest(host: String, port: Int) -> Endpoint<JSONEnvelope<Bool?>> {
        Endpoint(
            name: "autoconfigTest",
            method: .get,
            encodedPath: "autoconfig/test",
            query: [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
            ],
            isRetryable: true
        )
    }
}

// MARK: - Delegation

extension Endpoint where Response == [AccountDelegate] {
    /// `GET /api/delegations/{accountId}` — a bare array (verified live).
    public static func delegations(accountId: Int) -> Endpoint<[AccountDelegate]> {
        Endpoint(name: "delegations", method: .get, encodedPath: "delegations/\(accountId)", isRetryable: true)
    }
}

extension Endpoint where Response == AccountDelegate {
    /// `POST /api/delegations/{accountId}`. Body: `{"userId": …}`. Answers the
    /// delegation, bare, HTTP 201 (verified live). Delegating to yourself is a
    /// 400 `{"message": "Cannot delegate to yourself"}`, an existing one 409,
    /// a provisioned account 403.
    public static func grantDelegation(accountId: Int) -> Endpoint<AccountDelegate> {
        Endpoint(name: "grantDelegation", method: .post, encodedPath: "delegations/\(accountId)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/delegations/{accountId}/{userId}` — answers `[]`.
    public static func revokeDelegation(accountId: Int, userId: String) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "revokeDelegation",
            method: .delete,
            encodedPath: "delegations/\(accountId)/\(escape(userId))",
            isRetryable: false
        )
    }
}

// MARK: - OAuth

extension Endpoint where Response == JSONEnvelope<OAuthState> {
    /// `POST /api/oauth/state`. Body: `{"accountId": …}`. Minting a state is
    /// idempotent in effect but still a POST the flow repeats itself, so it is
    /// not auto-retried.
    public static var oauthState: Endpoint<JSONEnvelope<OAuthState>> {
        Endpoint(name: "oauthState", method: .post, encodedPath: "oauth/state", isRetryable: false)
    }
}

// MARK: - OCS account list

extension Endpoint where Response == OCSResponse<[AccountSummary]> {
    /// `GET /ocs/v2.php/apps/mail/account/list` — accounts including delegated
    /// ones, for other apps.
    public static var ocsAccountList: Endpoint<OCSResponse<[AccountSummary]>> {
        Endpoint(
            name: "ocsAccountList",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/apps/mail/account/list",
            isRetryable: true
        )
    }
}
