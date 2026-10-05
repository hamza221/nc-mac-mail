// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailCore
public import NCMailNet

/// A setting the server must validate, run online and never queued
/// ([ADR-0068](../../../../docs/decisions/0068-settings-commands.md)).
///
/// Account and mailbox ids are the mirror's local ids (ADR-0033); the command resolves the
/// server's. Passwords and private keys ride in the request bodies and are stored nowhere.
public enum SettingsCommand: Sendable {
    /// `PUT /api/accounts/{id}` — IMAP/SMTP host, port, security, user and password.
    case updateMailServer(accountId: Int64, AccountRequest)
    /// `GET /api/accounts/{id}/test`. The verdict is a `serverResult` row
    /// (``SettingsCommands/connectionTestKind``), not the outcome: the outcome says the test
    /// ran.
    case testConnection(accountId: Int64)
    case configureSieve(accountId: Int64, SieveAccountRequest)
    /// A 422 here is the Sieve parser's verdict, and comes back as
    /// ``CommandOutcome/failure(_:)`` carrying its message.
    case saveSieveScript(accountId: Int64, script: String)
    /// The managed filter list, in the server's own JSON shape.
    case saveFilters(accountId: Int64, filters: [AnyJSON])
    case saveOutOfOffice(accountId: Int64, OutOfOfficeRequest)
    case followSystemOutOfOffice(accountId: Int64)
    /// PEM certificate and optional PEM private key for the signed-in login.
    case importSMIME(pem: Data, privateKey: Data?)
    case deleteSMIME(certificateRemoteId: Int64)
    /// Links a certificate to the account itself (`aliasRemoteId` nil) or to one alias; a
    /// nil certificate unlinks.
    case setAliasCertificate(accountId: Int64, aliasRemoteId: Int64?, certificateRemoteId: Int64?)
    case delegate(accountId: Int64, userId: String)
    case revokeDelegation(accountId: Int64, userId: String)
    case createAccount(AccountRequest)
    case deleteAccount(accountId: Int64)
    /// `POST /api/mailboxes/{id}/repair`. Rate limited server-side: a 429 comes back as a
    /// failure carrying `MailError.rateLimited`.
    case repairMailbox(mailboxId: Int64)
    /// Mints the OAuth `state` for a Google/Microsoft account; it lands in a `serverResult`
    /// row (``SettingsCommands/oauthStateKind``) for the sign-in sheet to read.
    case startOAuth(accountId: Int64)
    /// `GET /api/autoconfig/ispdb/{host}/{email}` — the account form's first discovery step.
    /// Lands in a `serverResult` row (``SettingsCommands/autoconfigISPDBKind``). Online-only
    /// because the answer is only useful while the user is on the form.
    case lookupISPDB(host: String, email: String)
    /// `GET /api/autoconfig/mx/{email}` → ``SettingsCommands/autoconfigMXKind``.
    case lookupMX(email: String)
    /// `GET /api/autoconfig/test?host=&port=` → ``SettingsCommands/autoconfigTestKind``.
    case testConnectivity(host: String, port: Int)
}

/// The only thing a settings view awaits: did it work, and if not, what did the server say.
public enum CommandOutcome: Sendable {
    case success
    case failure(MailError)

    /// The server's own message, when it sent one — the Sieve parser's line and column for a
    /// 422 script.
    public var serverMessage: String? {
        guard case .failure(.server(_, let message)) = self else { return nil }
        return message
    }

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
