// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailSync
import Synchronization
import Testing

@testable import NextcloudMail

/// Answers by route from the recorded fixtures and remembers every request.
/// `FakeTransport` is the package's; the app's test bundle never links it (ADR-0029).
private final class SetupTransport: MailTransport {
    typealias Route = @Sendable (URLRequest) throws -> (status: Int, body: Data)?
    private let routes: Mutex<[Route]> = Mutex([])
    private let sent: Mutex<[URLRequest]> = Mutex([])

    var requests: [URLRequest] { sent.withLock { $0 } }

    func paths(_ method: String) -> [String] {
        requests.filter { $0.httpMethod == method }.compactMap { $0.url?.path }
    }

    func on(_ method: String, _ matches: @escaping @Sendable (String) -> Bool, status: Int = 200, fixture: String) {
        on(method, matches, status: status) { try FixtureBytes.data(fixture) }
    }

    func on(
        _ method: String, _ matches: @escaping @Sendable (String) -> Bool, status: Int = 200,
        body: @escaping @Sendable () throws -> Data
    ) {
        routes.withLock {
            $0.append { request in
                guard request.httpMethod == method, matches(request.url?.path ?? "") else { return nil }
                return (status, try body())
            }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // As the real transport does: a cancelled task's request never leaves.
        try Task.checkCancellation()
        sent.withLock { $0.append(request) }
        guard let url = request.url else { throw MailError.transport(URLError(.badURL)) }
        let answer = try routes.withLock { routes in try routes.lazy.compactMap { try $0(request) }.first }
        let (status, body) = answer ?? (404, Data())
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw MailError.transport(URLError(.badServerResponse)) }
        return (body, response)
    }
}

/// Records the consent URL and answers as told; `.granted` only after the poll says so.
/// `hangs` keeps the window open until the flow is cancelled, as a user leaving it would.
@MainActor
private final class ScriptedConsent: OAuthConsenting {
    var answer: OAuthConsentResult
    var hangs = false
    private(set) var urls: [URL] = []
    private(set) var connectedWhenAsked: Bool?

    init(answer: OAuthConsentResult) { self.answer = answer }

    func obtainConsent(at url: URL, isConnected: @escaping @MainActor () async -> Bool) async -> OAuthConsentResult {
        urls.append(url)
        if hangs {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .aborted
        }
        guard answer == .granted else { return .aborted }
        let connected = await isConnected()
        connectedWhenAsked = connected
        return connected ? .granted : .aborted
    }
}

@MainActor
@Suite("Account setup flow")
struct AccountSetupModelTests {
    private struct Rig {
        let store: MailStore
        let identity: ServerIdentity
        let transport = SetupTransport()
        let consent: ScriptedConsent
        let model: AccountSetupModel

        init(consent: OAuthConsentResult = .granted, configure: (inout AccountSetupForm) -> Void = { _ in }) throws {
            store = try MailStore.inMemory()
            let server = try #require(URL(string: "https://cloud.example.com"))
            identity = ServerIdentity(serverURL: server, loginName: "user")
            let commands = SettingsCommands(
                store: store,
                client: MailClient(
                    server: server, credentials: BasicCredentials(loginName: "user", appPassword: "secret"),
                    transport: transport),
                identity: identity
            )
            var form = AccountSetupForm()
            form.accountName = "User"
            form.emailAddress = "user@example.com"
            form.password = "secret"
            configure(&form)
            let scripted = ScriptedConsent(answer: consent)
            self.consent = scripted
            model = AccountSetupModel(
                store: store,
                identity: identity,
                run: { await commands.run($0) },
                consent: scripted,
                timing: .init(loadingTimeout: .milliseconds(50), loadingPoll: .milliseconds(10)),
                form: form
            )
        }

        /// `POST /api/accounts` answering the recorded account in the success envelope, the
        /// shape `AccountsController::create` returns; `GET /api/accounts/{id}` the bare one.
        func acceptCreate() {
            transport.on("POST", { $0.hasSuffix("/api/accounts") }, status: 201) {
                let account = try Self.recordedAccount()
                return try JSONSerialization.data(withJSONObject: ["status": "success", "data": account])
            }
            transport.on("GET", { $0.hasSuffix("/api/accounts/1") }) {
                try JSONSerialization.data(withJSONObject: try Self.recordedAccount())
            }
        }

        // `nonisolated`: the transport's closures are not main-actor.
        nonisolated private static func recordedAccount() throws -> Any {
            let list = try JSONSerialization.jsonObject(with: try FixtureBytes.data("accounts.json")) as? [Any]
            return try #require(list?.first)
        }

        func run() async {
            model.submit()
            await model.finish()
        }
    }

    private static let ispdb: @Sendable (String) -> Bool = { $0.contains("/autoconfig/ispdb/") }
    private static let mx: @Sendable (String) -> Bool = { $0.contains("/autoconfig/mx/") }
    private static let probe: @Sendable (String) -> Bool = { $0.hasSuffix("/autoconfig/test") }

    @Test func autoViaISPDBShowsLookUpThenAuthThenLoading() async throws {
        let rig = try Rig()
        rig.transport.on("GET", Self.ispdb, fixture: "autoconfig-ispdb.json")
        rig.acceptCreate()

        await rig.run()

        #expect(rig.model.steps == [.lookingUp, .testingAuthentication, .loadingAccount])
        #expect(
            rig.model.steps.map(\.label) == ["Looking up configuration", "Testing authentication", "Loading account"])
        #expect(rig.model.feedback == nil)
        #expect(rig.model.step == nil)
        let created = try #require(rig.model.createdAccountId)
        #expect(try await rig.store.account(id: created)?.emailAddress == "user@example.com")
        // The discovered servers went into the request, with Auto's password.
        #expect(rig.model.form.imapHost == "imap.gmail.com" && rig.model.form.smtpPort == 465)
        let body = try #require(rig.transport.requests.first { $0.httpMethod == "POST" }?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["imapHost"] as? String == "imap.gmail.com")
        #expect(sent["imapPassword"] as? String == "secret")
        #expect(sent["authMethod"] as? String == "password")
        // The domain was asked first.
        #expect(rig.transport.paths("GET").first?.contains("/autoconfig/ispdb/example.com/") == true)
    }

    @Test func autoFallsBackToMXThenThePortProbe() async throws {
        let rig = try Rig()
        // The ISPDB's "unknown host" answer: the envelope with null data (Autoconfig.swift).
        rig.transport.on("GET", Self.ispdb) { Data(#"{"status":"success","data":null}"#.utf8) }
        rig.transport.on("GET", Self.mx, fixture: "autoconfig-mx.json")
        rig.transport.on("GET", Self.probe, fixture: "autoconfig-test.json")
        rig.acceptCreate()

        await rig.run()

        #expect(
            rig.model.steps == [.lookingUp, .checkingConnectivity, .testingAuthentication, .loadingAccount])
        #expect(rig.model.createdAccountId != nil)
        // ISPDB twice: the domain, then the MX host's last two labels.
        #expect(rig.transport.paths("GET").filter(Self.ispdb).count == 2)
        #expect(rig.transport.paths("GET").filter(Self.probe).count == 4)
        #expect(rig.model.form.imapHost == "mail.example.com")
        #expect(rig.model.form.imapPort == 993 && rig.model.form.imapSecurity == .ssl)
        #expect(rig.model.form.smtpPort == 465 && rig.model.form.smtpSecurity == .ssl)
    }

    @Test func noOpenPortIsDiscoveryFailedAndCreatesNothing() async throws {
        let rig = try Rig()
        rig.transport.on("GET", Self.ispdb) { Data(#"{"status":"success","data":null}"#.utf8) }
        rig.transport.on("GET", Self.mx, fixture: "autoconfig-mx.json")
        rig.acceptCreate()

        await rig.run()

        #expect(rig.model.steps == [.lookingUp, .checkingConnectivity])
        #expect(rig.model.feedback == .discoveryFailed)
        #expect(rig.transport.paths("POST").isEmpty)
        #expect(rig.model.createdAccountId == nil)
    }

    @Test(
        "a refused create shows the server's reason",
        arguments: [
            ("error-account-create-wrong-password.json", "IMAP username or password is wrong"),
            ("error-account-create-unreachable.json", "IMAP server is not reachable"),
        ])
    func refusedCreate(fixture: String, text: String) async throws {
        let rig = try Rig {
            $0.setMode(.manual); $0.setIMAPHost("mail.example.com")
        }
        rig.transport.on("POST", { $0.hasSuffix("/api/accounts") }, status: 400, fixture: fixture)

        await rig.run()

        #expect(rig.model.steps == [.testingAuthentication])
        #expect(rig.model.feedback?.text == text)
        #expect(try await rig.store.accounts().isEmpty)
        #expect(!rig.model.isRunning)
    }

    @Test func aRateLimitedCreateIsDiscoveryUnavailable() async throws {
        let rig = try Rig {
            $0.setMode(.manual); $0.setIMAPHost("mail.example.com")
        }
        rig.transport.on("POST", { $0.hasSuffix("/api/accounts") }, status: 429) { Data() }

        await rig.run()

        #expect(rig.model.feedback == .discoveryRateLimited)
    }

    @Test func aServerErrorIsTheGenericLine() async throws {
        let rig = try Rig {
            $0.setMode(.manual); $0.setIMAPHost("mail.example.com")
        }
        rig.transport.on("POST", { $0.hasSuffix("/api/accounts") }, status: 500) { Data() }

        await rig.run()

        #expect(rig.model.feedback == .generic)
    }

    @Test func autoWithoutAPasswordForANonOAuthHostIsPasswordRequired() async throws {
        let rig = try Rig {
            $0.password = ""
            $0.googleOAuthURL = "https://accounts.google.com/o?state=_state_&login_hint=_email_"
            $0.microsoftOAuthURL = "https://login.microsoftonline.com/o?state=_state_"
        }
        rig.transport.on("GET", Self.ispdb) { Data(#"{"status":"success","data":null}"#.utf8) }
        rig.transport.on("GET", Self.mx, fixture: "autoconfig-mx.json")
        rig.transport.on("GET", Self.probe, fixture: "autoconfig-test.json")

        await rig.run()

        #expect(rig.model.feedback == .passwordRequired)
        #expect(rig.transport.paths("POST").isEmpty)
    }

    @Test func googleOAuthMintsTheStateAndLoadsOnceTheTestPasses() async throws {
        let rig = try Rig(consent: .granted) {
            $0.password = ""
            $0.googleOAuthURL = "https://accounts.google.com/o?state=_state_&login_hint=_email_"
            $0.microsoftOAuthURL = "https://login.microsoftonline.com/o?state=_state_"
        }
        rig.transport.on("GET", Self.ispdb, fixture: "autoconfig-ispdb.json")
        rig.acceptCreate()
        rig.transport.on("POST", { $0.hasSuffix("/oauth/state") }, fixture: "oauth-state.json")
        rig.transport.on("GET", { $0.hasSuffix("/accounts/1/test") }, fixture: "account-test.json")

        await rig.run()

        #expect(
            rig.model.steps == [.lookingUp, .testingAuthentication, .awaitingConsent, .loadingAccount])
        #expect(
            rig.consent.urls.map(\.absoluteString)
                == ["https://accounts.google.com/o?state=REDACTED&login_hint=user%40example.com"])
        #expect(rig.consent.connectedWhenAsked == true)
        #expect(rig.model.createdAccountId != nil)
        #expect(rig.model.feedback == nil)
        let body = try #require(
            rig.transport.requests.first { $0.url?.path.hasSuffix("/api/accounts") == true }?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["authMethod"] as? String == "xoauth2")
        #expect(sent["imapPassword"] == nil)
    }

    @Test func closingTheConsentWindowDeletesTheTemporaryAccount() async throws {
        let rig = try Rig(consent: .aborted) {
            $0.setMode(.manual)
            $0.setIMAPHost("imap.gmail.com")
            $0.setIMAPUser("user@example.com")
            $0.googleOAuthURL = "https://accounts.google.com/o?state=_state_"
        }
        #expect(rig.model.buttonLabel == "Sign in with Google")
        rig.acceptCreate()
        rig.transport.on("POST", { $0.hasSuffix("/oauth/state") }, fixture: "oauth-state.json")
        rig.transport.on("DELETE", { $0.hasSuffix("/api/accounts/1") }) { Data("[]".utf8) }

        await rig.run()

        #expect(rig.model.steps == [.testingAuthentication, .awaitingConsent])
        #expect(rig.model.feedback == .consentAborted)
        #expect(rig.transport.paths("DELETE") == ["/index.php/apps/mail/api/accounts/1"])
        #expect(try await rig.store.accounts().isEmpty)
        #expect(rig.model.createdAccountId == nil)
    }

    @Test func cancellingWhileAwaitingConsentStillDeletesTheTemporaryAccount() async throws {
        let rig = try Rig {
            $0.setMode(.manual)
            $0.setIMAPHost("imap.gmail.com")
            $0.setIMAPUser("user@example.com")
            $0.googleOAuthURL = "https://accounts.google.com/o?state=_state_"
        }
        rig.consent.hangs = true
        rig.acceptCreate()
        rig.transport.on("POST", { $0.hasSuffix("/oauth/state") }, fixture: "oauth-state.json")
        rig.transport.on("DELETE", { $0.hasSuffix("/api/accounts/1") }) { Data("[]".utf8) }

        rig.model.submit()
        while rig.consent.urls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.model.buttonLabel == "Awaiting user consent")
        rig.model.cancel()
        await rig.model.finish()

        #expect(rig.transport.paths("DELETE") == ["/index.php/apps/mail/api/accounts/1"])
        #expect(try await rig.store.accounts().isEmpty)
        #expect(rig.model.feedback == .consentAborted)
        #expect(!rig.model.isRunning)
    }

    @Test func editingAFieldClearsTheFeedback() async throws {
        let rig = try Rig {
            $0.setMode(.manual); $0.setIMAPHost("mail.example.com")
        }
        rig.transport.on("POST", { $0.hasSuffix("/api/accounts") }, status: 500) { Data() }
        await rig.run()
        #expect(rig.model.feedback != nil)

        rig.model.form.setIMAPPassword("another")

        #expect(rig.model.feedback == nil)
    }

    @Test func theLoginFlagsHideTheFormAndPickTheDefaults() throws {
        let rig = try Rig {
            $0.accountName = ""; $0.emailAddress = ""
        }
        var login = LoginRecord(identity: rig.identity, allowNewAccounts: false, importanceClassificationDefault: false)
        login.googleOauthUrl = "https://accounts.google.com/o?state=_state_"
        rig.model.apply(login: login)

        #expect(rig.model.allowsNewAccounts == false)
        #expect(rig.model.form.classificationEnabled == false)
        #expect(rig.model.form.googleOAuthURL != nil)

        rig.model.apply(login: nil)
        #expect(rig.model.allowsNewAccounts == nil)
    }
}

@MainActor
@Suite("OAuth consent polling")
struct OAuthConsentPollingTests {
    /// The limit is clock-bound at the in-tree 10 s: the 1 ms sleeps resume on the main
    /// actor, which a full parallel run shares with every `@MainActor` suite, and a full
    /// run was measured aborting a five-second limit before the third poll ran. A passing
    /// run returns at the third call; only a failing one waits this long.
    @Test func grantedOnTheFirstPassingTest() async {
        var calls = 0
        let result = await OAuthConsentSession.poll(
            {
                calls += 1
                return calls == 3
            }, every: .milliseconds(1), for: .seconds(10))
        #expect(result == .granted)
        #expect(calls == 3)
    }

    @Test func abortedAtTheTimeLimit() async {
        let result = await OAuthConsentSession.poll({ false }, every: .milliseconds(5), for: .milliseconds(30))
        #expect(result == .aborted)
    }

    @Test func abortedWhenCancelled() async {
        let task = Task { @MainActor in
            await OAuthConsentSession.poll({ false }, every: .seconds(2), for: .seconds(600))
        }
        task.cancel()
        #expect(await task.value == .aborted)
    }
}
