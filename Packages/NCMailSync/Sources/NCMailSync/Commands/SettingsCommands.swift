// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import NCMailCore
public import NCMailNet
public import NCMailStore
internal import OSLog

/// Runs the settings the server must validate, online, and writes what the server then holds
/// into the store ([ADR-0068](../../../../docs/decisions/0068-settings-commands.md)).
///
/// The one deliberate exception to "queue every mutation": a Sieve script, a credential or a
/// filter queued offline could be rejected hours later with nobody looking at the form. So
/// the request happens now, a failure comes back as ``CommandOutcome/failure(_:)`` with the
/// server's message while the user is still on the form, and a success is written into the
/// mirror — the view awaits only the outcome and reads the result from the database like
/// everything else.
///
/// One actor per login. Nothing is retried here beyond what `MailClient` does for an
/// idempotent read; a 429 is the user's to retry.
public actor SettingsCommands {
    private let store: MailStore
    private let client: MailClient
    private let identity: ServerIdentity
    private let now: @Sendable () -> Int64

    /// `serverResult.kind` of a connection test's verdict, keyed by local account id. The
    /// payload is ADR-0067's `ServerResultPayload.ready({"ok": true|false})`.
    public static let connectionTestKind = "accountTest"
    /// `serverResult.kind` of a minted OAuth state, keyed by local account id. The payload
    /// is `ServerResultPayload.ready({"state": "…"})`.
    public static let oauthStateKind = "oauthState"
    /// `serverResult.kind` of an ISPDB lookup, keyed by ``autoconfigISPDBKey(host:email:)``.
    /// The payload is `ready({"imapConfig": {…}|null, "smtpConfig": {…}|null})`, or `empty`
    /// when the database does not know the host.
    public static let autoconfigISPDBKind = "autoconfigIspdb"
    /// `serverResult.kind` of an MX lookup, keyed by the address. `ready({"hosts": […]})`,
    /// or `empty` when the domain has no MX record.
    public static let autoconfigMXKind = "autoconfigMx"
    /// `serverResult.kind` of a port probe, keyed by ``autoconfigTestKey(host:port:)``.
    /// `ready({"ok": Bool})`.
    public static let autoconfigTestKind = "autoconfigTest"

    public static func autoconfigISPDBKey(host: String, email: String) -> String { "\(host) \(email)" }

    public static func autoconfigTestKey(host: String, port: Int) -> String { "\(host):\(port)" }

    public init(
        store: MailStore,
        client: MailClient,
        identity: ServerIdentity,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.store = store
        self.client = client
        self.identity = identity
        self.now = now
    }

    public func run(_ command: SettingsCommand) async -> CommandOutcome {
        let name = Self.name(of: command)
        do {
            try await perform(command)
            CommandLog.commands.info("command \(name, privacy: .public) succeeded")
            return .success
        } catch let error as MailError {
            CommandLog.commands.error(
                "command \(name, privacy: .public) failed: \(error.description, privacy: .public)")
            return .failure(error)
        } catch let error as CommandError {
            CommandLog.commands.error(
                "command \(name, privacy: .public) failed: \(error.description, privacy: .public)")
            return .failure(error.mailError)
        } catch {
            CommandLog.commands.error("command \(name, privacy: .public) failed: transport")
            return .failure(.transport(error))
        }
    }

    // MARK: - The commands

    private func perform(_ command: SettingsCommand) async throws {
        switch command {
        case .updateMailServer(let accountId, let request):
            let account = try await account(accountId)
            // The PUT answers a partial account (live, Mail 5.12: `order`, `editorMode` and
            // the special-mailbox ids come back null while the server keeps them), so the
            // mirror is written from a fresh GET, not from the answer.
            _ = try await client.put(Endpoint.updateAccount(id: Int(account.remoteId)), body: request)
            _ = try await refreshAccount(account)

        case .testConnection(let accountId):
            let account = try await account(accountId)
            let answer = try await client.get(Endpoint.testAccount(accountId: Int(account.remoteId)))
            try await writeResult(
                kind: Self.connectionTestKind,
                accountId: accountId,
                payload: ["ok": .bool(answer.data ?? false)]
            )

        case .configureSieve(let accountId, let request):
            let account = try await account(accountId)
            _ = try await client.put(Endpoint.configureSieve(accountId: Int(account.remoteId)), body: request)
            let refreshed = try await refreshAccount(account)
            if request.sieveEnabled {
                try await refreshSieve(refreshed, script: true, filters: true, outOfOffice: true)
            } else {
                try await store.upsert(
                    sieveState: SieveStateRecord(accountId: accountId, sieveEnabled: false, fetchedAt: now()))
            }

        case .saveSieveScript(let accountId, let script):
            let account = try await account(accountId)
            _ = try await client.put(
                Endpoint.updateSieveScript(accountId: Int(account.remoteId)),
                body: SieveScriptRequest(script: script)
            )
            try await refreshSieve(account, script: true, filters: true, outOfOffice: false)

        case .saveFilters(let accountId, let filters):
            let account = try await account(accountId)
            _ = try await client.put(
                Endpoint.updateFilters(accountId: Int(account.remoteId)), body: FiltersRequest(filters: filters))
            // The filters live in the active script, so both are re-read.
            try await refreshSieve(account, script: true, filters: true, outOfOffice: false)

        case .saveOutOfOffice(let accountId, let request):
            let account = try await account(accountId)
            _ = try await client.post(Endpoint.updateOutOfOffice(accountId: Int(account.remoteId)), body: request)
            let refreshed = try await refreshAccount(account)
            try await refreshSieve(refreshed, script: true, filters: false, outOfOffice: true)

        case .followSystemOutOfOffice(let accountId):
            let account = try await account(accountId)
            _ = try await client.post(Endpoint.followSystemOutOfOffice(accountId: Int(account.remoteId)))
            let refreshed = try await refreshAccount(account)
            try await refreshSieve(refreshed, script: true, filters: false, outOfOffice: true)

        case .importSMIME(let pem, let privateKey):
            var form = MultipartForm()
            form.append(
                .file(
                    name: "certificate", filename: "certificate.pem", contentType: "application/x-pem-file", data: pem))
            if let privateKey {
                form.append(
                    .file(
                        name: "privateKey", filename: "key.pem", contentType: "application/x-pem-file", data: privateKey
                    ))
            }
            _ = try await client.upload(Endpoint.uploadSmimeCertificate, multipart: form)
            try await refreshCertificates()

        case .deleteSMIME(let certificateRemoteId):
            _ = try await client.delete(Endpoint.deleteSmimeCertificate(id: Int(certificateRemoteId)))
            try await refreshCertificates()

        case .setAliasCertificate(let accountId, let aliasRemoteId, let certificateRemoteId):
            let account = try await account(accountId)
            let certificate = certificateRemoteId.map(Int.init)
            if let aliasRemoteId {
                guard let alias = try await store.alias(accountId: accountId, remoteId: aliasRemoteId) else {
                    throw CommandError.notMirrored
                }
                _ = try await client.put(
                    Endpoint.updateAlias(accountId: Int(account.remoteId), aliasId: Int(aliasRemoteId)),
                    body: AliasRequest(alias: alias.email, aliasName: alias.name ?? "", smimeCertificateId: certificate)
                )
                try await refreshAliases(account)
            } else {
                _ = try await client.put(
                    Endpoint.setAccountSmimeCertificate(accountId: Int(account.remoteId)),
                    body: SmimeCertificateLinkRequest(smimeCertificateId: certificate)
                )
                _ = try await refreshAccount(account)
            }

        case .delegate(let accountId, let userId):
            let account = try await account(accountId)
            _ = try await client.post(
                Endpoint.grantDelegation(accountId: Int(account.remoteId)), body: DelegationRequest(userId: userId))
            try await refreshDelegations(account)

        case .revokeDelegation(let accountId, let userId):
            let account = try await account(accountId)
            _ = try await client.delete(Endpoint.revokeDelegation(accountId: Int(account.remoteId), userId: userId))
            try await refreshDelegations(account)

        case .createAccount(let request):
            // Same serializer as the update's partial answer: only its id is trusted.
            let answer = try await client.post(Endpoint.createAccount, body: request)
            let created = try await client.get(Endpoint.account(id: answer.data.value.id))
            try await store.upsert(accounts: [try MirrorMapping.accountWrite(created, identity: identity)])

        case .deleteAccount(let accountId):
            let account = try await account(accountId)
            _ = try await client.delete(Endpoint.deleteAccount(id: Int(account.remoteId)))
            try await store.deleteAccount(id: accountId)

        case .repairMailbox(let mailboxId):
            guard let mailbox = try await store.mailbox(id: mailboxId) else { throw CommandError.notMirrored }
            let account = try await account(mailbox.accountId)
            _ = try await client.post(Endpoint.repairMailbox(id: Int(mailbox.remoteId)))
            // Repair re-reads the folder server-side; the mailbox list is what can change.
            let list = try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId)))
            try await store.upsert(
                mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: account.id) },
                accountId: account.id
            )

        case .startOAuth(let accountId):
            let account = try await account(accountId)
            let answer = try await client.post(
                Endpoint.oauthState, body: OAuthStateRequest(accountId: Int(account.remoteId)))
            try await writeResult(
                kind: Self.oauthStateKind, accountId: accountId, payload: ["state": .string(answer.data.state)])

        case .lookupISPDB(let host, let email):
            let answer = try await client.get(Endpoint.autoconfigISPDB(host: host, email: email))
            let payload: ServerResultPayload =
                if let result = answer.data, result.imapConfig != nil || result.smtpConfig != nil {
                    .ready(
                        .object([
                            "imapConfig": result.imapConfig.map(Self.json) ?? .null,
                            "smtpConfig": result.smtpConfig.map(Self.json) ?? .null,
                        ]))
                } else {
                    .empty
                }
            try await writeResult(
                kind: Self.autoconfigISPDBKind, key: Self.autoconfigISPDBKey(host: host, email: email), payload)

        case .lookupMX(let email):
            let hosts = try await client.get(Endpoint.autoconfigMX(email: email)).data ?? []
            try await writeResult(
                kind: Self.autoconfigMXKind, key: email,
                hosts.isEmpty ? .empty : .ready(.object(["hosts": .array(hosts.map(AnyJSON.string))])))

        case .testConnectivity(let host, let port):
            let answer = try await client.get(Endpoint.autoconfigTest(host: host, port: port))
            try await writeResult(
                kind: Self.autoconfigTestKind, key: Self.autoconfigTestKey(host: host, port: port),
                .ready(.object(["ok": .bool(answer.data ?? false)])))
        }
    }

    private static func json(_ server: AutoconfigServer) -> AnyJSON {
        .object([
            "username": server.username.map(AnyJSON.string) ?? .null,
            "host": .string(server.host),
            "port": .int(server.port),
            "security": server.security.map(AnyJSON.string) ?? .null,
        ])
    }

    // MARK: - Writing what the server now holds

    private func refreshAccount(_ account: AccountRecord) async throws -> AccountRecord {
        let answer = try await client.get(Endpoint.account(id: Int(account.remoteId)))
        let rows = try await store.upsert(accounts: [try MirrorMapping.accountWrite(answer, identity: identity)])
        return rows.first ?? account
    }

    /// Re-reads the parts of the Sieve state the command can have changed and keeps the rest
    /// from the previous row.
    private func refreshSieve(_ account: AccountRecord, script: Bool, filters: Bool, outOfOffice: Bool) async throws {
        let remoteId = Int(account.remoteId)
        let scriptAnswer: SieveScript?? =
            script ? .some(try await client.get(Endpoint.sieveScript(accountId: remoteId))) : nil
        // A server with ManageSieve trouble answers the filter route with a 500 page
        // (fixture `error-filter-500.html`); the filters keep their previous value then.
        let filtersAnswer: [MailFilter]?? =
            filters ? (try? await client.get(Endpoint.filters(accountId: remoteId))).map { .some($0) } : nil
        let outOfOfficeAnswer: OutOfOfficeState?? =
            outOfOffice ? .some(try await client.get(Endpoint.outOfOffice(accountId: remoteId)).data.state) : nil
        let record = try MirrorMapping.sieveStateRecord(
            account: account,
            script: scriptAnswer,
            filters: filtersAnswer,
            outOfOffice: outOfOfficeAnswer,
            previous: try await store.sieveState(accountId: account.id),
            fetchedAt: now()
        )
        try await store.upsert(sieveState: record)
    }

    private func refreshCertificates() async throws {
        let answer = try await client.get(Endpoint.smimeCertificates)
        try await store.replaceSmimeCertificates(
            try MirrorMapping.smimeCertificateRecords(answer.data, loginId: try await loginId()),
            loginId: try await loginId()
        )
    }

    private func refreshAliases(_ account: AccountRecord) async throws {
        let aliases = try await client.get(Endpoint.aliases(accountId: Int(account.remoteId)))
        let previous = try await store.aliases(accountId: account.id)
        try await store.replaceAliases(
            aliases.map { alias in
                AliasRecord(
                    accountId: account.id,
                    remoteId: Int64(alias.id),
                    email: alias.alias,
                    name: alias.name,
                    signature: alias.signature,
                    provisioned: alias.provisioned,
                    smimeCertificateRemoteId: alias.smimeCertificateId.map(Int64.init),
                    rawJSON: previous.first { $0.remoteId == Int64(alias.id) }?.rawJSON ?? "{}"
                )
            },
            accountId: account.id
        )
    }

    private func refreshDelegations(_ account: AccountRecord) async throws {
        let delegates = try await client.get(Endpoint.delegations(accountId: Int(account.remoteId)))
        try await store.replaceDelegations(
            MirrorMapping.delegationRecords(delegates, accountId: account.id),
            accountId: account.id
        )
    }

    /// Written in ADR-0067's shape (`{"status":"ready","data":…}`), so `ServerResultPayload`
    /// decodes it like every other server-result row.
    private func writeResult(kind: String, accountId: Int64, payload: [String: AnyJSON]) async throws {
        try await writeResult(kind: kind, key: String(accountId), .ready(.object(payload)))
    }

    private func writeResult(kind: String, key: String, _ payload: ServerResultPayload) async throws {
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: try await loginId(),
                kind: kind,
                key: key,
                payloadJSON: try payload.jsonText(),
                fetchedAt: now()
            )
        )
    }

    // MARK: - Lookups

    private func account(_ accountId: Int64) async throws -> AccountRecord {
        guard let account = try await store.account(id: accountId) else { throw CommandError.notMirrored }
        return account
    }

    private func loginId() async throws -> Int64 {
        guard let id = try await store.ensureLogin(identity).id else { throw CommandError.notMirrored }
        return id
    }

    static func name(of command: SettingsCommand) -> String {
        switch command {
        case .updateMailServer: "updateMailServer"
        case .testConnection: "testConnection"
        case .configureSieve: "configureSieve"
        case .saveSieveScript: "saveSieveScript"
        case .saveFilters: "saveFilters"
        case .saveOutOfOffice: "saveOutOfOffice"
        case .followSystemOutOfOffice: "followSystemOutOfOffice"
        case .importSMIME: "importSMIME"
        case .deleteSMIME: "deleteSMIME"
        case .setAliasCertificate: "setAliasCertificate"
        case .delegate: "delegate"
        case .revokeDelegation: "revokeDelegation"
        case .createAccount: "createAccount"
        case .deleteAccount: "deleteAccount"
        case .repairMailbox: "repairMailbox"
        case .startOAuth: "startOAuth"
        case .lookupISPDB: "lookupISPDB"
        case .lookupMX: "lookupMX"
        case .testConnectivity: "testConnectivity"
        }
    }
}

/// What a command can fail with before it reaches the server.
enum CommandError: Error, CustomStringConvertible {
    /// The account, mailbox or alias named is not in the mirror, so there is no server id to
    /// send. Answered as a 404, which is what the server would have said.
    case notMirrored

    var mailError: MailError { .notFound }

    var description: String { "notMirrored" }
}

/// Command names and outcomes only. Never a host, a user, a password, a script or a key.
enum CommandLog {
    static let commands = Logger(subsystem: "com.nextcloud.mail.macos", category: "commands")
}
