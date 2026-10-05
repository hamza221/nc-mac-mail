// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// ADR-0068: the view awaits only the outcome; on success the store holds what the server
/// now holds, and on failure the server's own message comes back.
@Suite("Settings commands")
struct SettingsCommandsTests {
    private func make() async throws -> (QueueTest.Fixture, SettingsCommands) {
        let fixture = try await QueueTest.make()
        let commands = SettingsCommands(
            store: fixture.store,
            client: try MirrorTest.client(fixture.transport),
            identity: MailStoreFixtures.identity,
            now: { 1_800_000_000 }
        )
        return (fixture, commands)
    }

    private static func route(_ method: String, _ test: @escaping @Sendable (String) -> Bool) -> RequestMatcher {
        RequestMatcher.method(method) && RequestMatcher("\(method) path") { test($0.url?.path ?? "") }
    }

    @Test func aSieveSyntaxErrorComesBackWithTheServersMessage() async throws {
        let (fixture, commands) = try await make()
        // Recorded live: ManageSieve on, a script that does not parse.
        await fixture.transport.stub(
            Self.route("PUT") { $0.hasSuffix("/sieve/active/1") },
            with: try .fixture("error-sieve-script-422.json", status: 422)
        )

        let outcome = await commands.run(.saveSieveScript(accountId: fixture.accountId, script: "this is not sieve;"))

        guard case .failure(.server(let status, let message)) = outcome else {
            Issue.record("expected a server failure, got \(outcome)")
            return
        }
        #expect(status == 422)
        #expect(message?.contains("Expected token") == true)
        #expect(outcome.serverMessage == message)
        // Nothing was accepted, so nothing was written.
        #expect(try await fixture.store.sieveState(accountId: fixture.accountId) == nil)
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func aSavedScriptIsReadBackIntoTheStore() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(Self.route("PUT") { $0.hasSuffix("/sieve/active/1") }, with: .status(200))
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/sieve/active/1") },
            with: try .fixture("sieve-active-enabled.json")
        )
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/filter/1") }, with: try .fixture("filters-enabled.json"))

        let outcome = await commands.run(.saveSieveScript(accountId: fixture.accountId, script: "keep;"))

        #expect(outcome.isSuccess)
        let state = try #require(try await fixture.store.sieveState(accountId: fixture.accountId))
        #expect(state.script != nil)
        #expect(state.fetchedAt == 1_800_000_000)
    }

    @Test func aDelegationIsReadBackIntoTheStore() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("POST") { $0.hasSuffix("/delegations/1") }, with: try .fixture("delegation-created.json"))
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/delegations/1") }, with: try .fixture("delegations.json"))

        #expect(await commands.run(.delegate(accountId: fixture.accountId, userId: "alice")).isSuccess)

        let rows = try await fixture.store.delegations(accountId: fixture.accountId)
        #expect(rows.map(\.userId) == ["alice"])
        let post = try #require(await fixture.transport.requests.first { $0.httpMethod == "POST" })
        #expect(try QueueTest.body(post)["userId"] as? String == "alice")
    }

    @Test func theConnectionTestVerdictIsARow() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/accounts/1/test") }, with: try .fixture("account-test.json"))

        #expect(await commands.run(.testConnection(accountId: fixture.accountId)).isSuccess)

        let loginId = try #require(try await fixture.store.ensureLogin(MailStoreFixtures.identity).id)
        let row = try #require(
            try await fixture.store.serverResult(
                kind: SettingsCommands.connectionTestKind, key: String(fixture.accountId), loginId: loginId
            )
        )
        #expect(try ServerResultPayload(payloadJSON: row.payloadJSON) == .ready(.object(["ok": .bool(true)])))
    }

    @Test func theOAuthStateIsARow() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("POST") { $0.hasSuffix("/oauth/state") }, with: try .fixture("oauth-state.json"))

        #expect(await commands.run(.startOAuth(accountId: fixture.accountId)).isSuccess)

        let loginId = try #require(try await fixture.store.ensureLogin(MailStoreFixtures.identity).id)
        #expect(
            try await fixture.store.serverResult(
                kind: SettingsCommands.oauthStateKind, key: String(fixture.accountId), loginId: loginId
            ) != nil
        )
    }

    @Test func anImportedCertificateIsReadBackIntoTheStore() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            RequestMatcher.method("POST") && RequestMatcher.multipartField(named: "certificate"),
            with: try .fixture("smime-certificate-created.json")
        )
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/smime/certificates") }, with: try .fixture("smime-certificates.json"))

        let outcome = await commands.run(
            .importSMIME(pem: Data("-----BEGIN CERTIFICATE-----".utf8), privateKey: Data("key".utf8)))

        #expect(outcome.isSuccess)
        let loginId = try #require(try await fixture.store.ensureLogin(MailStoreFixtures.identity).id)
        #expect(try await !fixture.store.smimeCertificates(loginId: loginId).isEmpty)
    }

    @Test func deletingAnAccountRemovesItsRow() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(Self.route("DELETE") { $0.hasSuffix("/accounts/1") }, with: .status(200))

        #expect(await commands.run(.deleteAccount(accountId: fixture.accountId)).isSuccess)
        #expect(try await fixture.store.account(id: fixture.accountId) == nil)
    }

    @Test func aRateLimitedRepairIsAFailureAndQueuesNothing() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(Self.route("POST") { $0.hasSuffix("/repair") }, with: .retryAfter(60))

        let outcome = await commands.run(.repairMailbox(mailboxId: fixture.inboxId))

        guard case .failure(.rateLimited) = outcome else {
            Issue.record("expected rateLimited, got \(outcome)")
            return
        }
        #expect(try await fixture.rows().isEmpty)
    }

    @Test func anUnknownAccountIsANotFoundWithoutARequest() async throws {
        let (fixture, commands) = try await make()
        guard case .failure(.notFound) = await commands.run(.testConnection(accountId: 9_999)) else {
            Issue.record("expected notFound")
            return
        }
        #expect(await fixture.transport.requests.isEmpty)
    }

    private func row(_ fixture: QueueTest.Fixture, kind: String, key: String) async throws -> ServerResultPayload? {
        let loginId = try #require(try await fixture.store.ensureLogin(MailStoreFixtures.identity).id)
        guard let row = try await fixture.store.serverResult(kind: kind, key: key, loginId: loginId) else { return nil }
        return try ServerResultPayload(payloadJSON: row.payloadJSON)
    }

    @Test func anISPDBAnswerIsARowWithBothServers() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("GET") { $0.contains("/autoconfig/ispdb/") }, with: try .fixture("autoconfig-ispdb.json"))

        #expect(await commands.run(.lookupISPDB(host: "gmail.com", email: "user@gmail.com")).isSuccess)

        let key = SettingsCommands.autoconfigISPDBKey(host: "gmail.com", email: "user@gmail.com")
        guard case .ready(let data) = try await row(fixture, kind: SettingsCommands.autoconfigISPDBKind, key: key)
        else {
            Issue.record("expected a ready row")
            return
        }
        let imap = data.objectValue?["imapConfig"]?.objectValue
        #expect(imap?.string("host") == "imap.gmail.com")
        #expect(imap?["port"] == .int(993))
        #expect(imap?.string("security") == "ssl")
        #expect(data.objectValue?["smtpConfig"]?.objectValue?["port"] == .int(465))
    }

    @Test func anMXAnswerAndAPortProbeAreRows() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("GET") { $0.contains("/autoconfig/mx/") }, with: try .fixture("autoconfig-mx.json"))
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/autoconfig/test") }, with: try .fixture("autoconfig-test.json"))

        #expect(await commands.run(.lookupMX(email: "user@example.com")).isSuccess)
        #expect(await commands.run(.testConnectivity(host: "mail.example.com", port: 993)).isSuccess)

        let mx = try await row(fixture, kind: SettingsCommands.autoconfigMXKind, key: "user@example.com")
        #expect(mx == .ready(.object(["hosts": .array([.string("mail.example.com"), .string("mail.example.com")])])))
        let probe = try await row(
            fixture, kind: SettingsCommands.autoconfigTestKind,
            key: SettingsCommands.autoconfigTestKey(host: "mail.example.com", port: 993))
        #expect(probe == .ready(.object(["ok": .bool(true)])))
    }

    @Test func aFailedLookupIsAFailureAndWritesNoRow() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(Self.route("GET") { $0.contains("/autoconfig/mx/") }, with: .status(404))

        guard case .failure(.notFound) = await commands.run(.lookupMX(email: "user@example.com")) else {
            Issue.record("expected notFound")
            return
        }
        #expect(try await row(fixture, kind: SettingsCommands.autoconfigMXKind, key: "user@example.com") == nil)
    }

    @Test func aRefusedCreateIsConnectFailedAndWritesNoAccount() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("POST") { $0.hasSuffix("/accounts") },
            with: try .fixture("error-account-create-wrong-password.json", status: 400))
        let before = try await fixture.store.accounts().count

        let outcome = await commands.run(
            .createAccount(
                AccountRequest(
                    accountName: "Probe", emailAddress: "probe@example.com",
                    imapHost: "mail.example.com", imapPort: 993, imapSslMode: "ssl", imapUser: "probe@example.com",
                    smtpHost: "mail.example.com", smtpPort: 587, smtpSslMode: "tls", smtpUser: "probe@example.com",
                    imapPassword: "wrong", smtpPassword: "wrong")))

        guard case .failure(.connectFailed("IMAP", "AUTHENTICATION_WRONG_PASSWORD")) = outcome else {
            Issue.record("expected connectFailed, got \(outcome)")
            return
        }
        #expect(try await fixture.store.accounts().count == before)
    }

    private static let mailServerRequest = AccountRequest(
        accountName: "admin", emailAddress: "user@example.com",
        imapHost: "mail.example.com", imapPort: 993, imapSslMode: "ssl", imapUser: "user@example.com",
        smtpHost: "mail.example.com", smtpPort: 465, smtpSslMode: "ssl", smtpUser: "user@example.com")

    /// Recorded live: the PUT answers `order`, `editorMode` and every special-mailbox id as
    /// null while the server keeps them. The mirror must end up with the GET's full row.
    @Test func aMailServerUpdateWritesTheReReadAccountNotThePartialAnswer() async throws {
        let (fixture, commands) = try await make()
        await fixture.transport.stub(
            Self.route("PUT") { $0.hasSuffix("/api/accounts/1") }, with: try .fixture("account-updated.json"))
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/api/accounts/1") }, with: try .fixture("account.json"))

        #expect(
            await commands.run(.updateMailServer(accountId: fixture.accountId, Self.mailServerRequest)).isSuccess)

        let account = try #require(try await fixture.store.account(id: fixture.accountId))
        #expect(account.editorMode == "plaintext")
        #expect(account.draftsMailboxId == 2)
        #expect(account.sentMailboxId == 5)
        #expect(account.trashMailboxId == 1)
        #expect(account.junkMailboxId == 4)
        let paths = await fixture.transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(paths.last?.hasPrefix("GET") == true)
    }

    /// The create's success answer comes from the same serializer as the update's; it is not
    /// recorded on its own because recording it creates a real account. Only its id is used.
    @Test func aCreatedAccountIsReReadBeforeItIsWritten() async throws {
        let (fixture, commands) = try await make()
        try await fixture.store.deleteAccount(id: fixture.accountId)
        await fixture.transport.stub(
            Self.route("POST") { $0.hasSuffix("/api/accounts") }, with: try .fixture("account-updated.json"))
        await fixture.transport.stub(
            Self.route("GET") { $0.hasSuffix("/api/accounts/1") }, with: try .fixture("account.json"))

        #expect(await commands.run(.createAccount(Self.mailServerRequest)).isSuccess)

        let account = try #require(try await fixture.store.accounts().first { $0.remoteId == 1 })
        #expect(account.editorMode == "plaintext")
        #expect(account.draftsMailboxId == 2)
    }
}

/// The 422 from the acceptance, against the real server. Off by default — it switches
/// ManageSieve on for the test account and off again (ADR-0080 scratch lifecycle).
///
/// ```
/// NCMAIL_LIVE_SYNC=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter aLiveSieveSyntaxErrorCarriesTheServersMessage
/// ```
@Suite("Settings commands against a live server")
struct SettingsCommandsLiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_SYNC"]

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: SettingsCommandsLiveTests.serverEnvironment != nil))
    func aLiveSieveSyntaxErrorCarriesTheServersMessage() async throws {
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
        let host = try #require(
            (try? JSONDecoder().decode([String: AnyJSONValue].self, from: Data(account.rawJSON.utf8)))?["imapHost"]?
                .string
        )
        let commands = SettingsCommands(store: store, client: client, identity: identity)

        let enable = SieveAccountRequest(
            sieveEnabled: true, sieveHost: host, sievePort: 4190, sieveUser: "", sievePassword: "", sieveSslMode: "tls"
        )
        let disable = SieveAccountRequest(
            sieveEnabled: false, sieveHost: "", sievePort: 4190, sieveUser: "", sievePassword: "", sieveSslMode: "none"
        )
        var clock = ContinuousClock.now
        let configured = await commands.run(.configureSieve(accountId: account.id, enable))
        let configureTime = ContinuousClock.now - clock
        #expect(configured.isSuccess)

        clock = ContinuousClock.now
        let outcome = await commands.run(
            .saveSieveScript(accountId: account.id, script: "require [\"fileinto\"];\nthis is not sieve;\n"))
        let saveTime = ContinuousClock.now - clock
        let restored = await commands.run(.configureSieve(accountId: account.id, disable))

        guard case .failure(.server(let status, let message)) = outcome else {
            Issue.record("expected a 422, got \(outcome)")
            return
        }
        #expect(status == 422)
        #expect(message?.contains("Expected token") == true)
        #expect(restored.isSuccess)
        #expect(try await store.sieveState(accountId: account.id)?.sieveEnabled == false)
        reportQueueMeasurement("live configureSieve \(configureTime), rejected saveSieveScript \(saveTime)")
    }
}

/// Just enough JSON to read one string field out of `account.rawJSON` in the live test.
private enum AnyJSONValue: Decodable {
    case string(String)
    case other

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
