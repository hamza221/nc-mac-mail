// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// Runs the account form's submit flow (`AccountForm.vue`'s `detectConfig` + `onSubmit`).
///
/// Every server step is a `SettingsCommand` (ADR-0068): the model awaits its outcome and
/// reads what it wrote — discovered servers, MX hosts, the probe verdict, the OAuth state,
/// the new account row — from the store. It never sees a response body.
@MainActor
@Observable
final class AccountSetupModel {
    /// The button-label steps, in the order the web client shows them.
    enum Step: Equatable {
        case lookingUp
        case checkingConnectivity
        case testingAuthentication
        case awaitingConsent
        case loadingAccount

        var label: String {
            switch self {
            case .lookingUp: String(localized: "Looking up configuration")
            case .checkingConnectivity: String(localized: "Checking mail host connectivity")
            case .testingAuthentication: String(localized: "Testing authentication")
            case .awaitingConsent: String(localized: "Awaiting user consent")
            case .loadingAccount: String(localized: "Loading account")
            }
        }
    }

    struct Timing {
        /// How long "Loading account" waits for the first mailboxes before closing anyway.
        var loadingTimeout: Duration = .seconds(30)
        var loadingPoll: Duration = .milliseconds(250)
    }

    var form: AccountSetupForm {
        didSet {
            // Editing any field clears the feedback (§1.5); the flow's own writes happen
            // while running, when the line is the flow's to set.
            if step == nil, feedback != nil, oldValue != form { feedback = nil }
        }
    }
    private(set) var step: Step?
    private(set) var feedback: AccountSetupFeedback?
    /// Every step the current run passed through, in order — what the button showed.
    private(set) var steps: [Step] = []
    /// The account that was created and finished loading; the sheet closes on it.
    private(set) var createdAccountId: Int64?
    /// nil = unknown, which counts as allowed (server-flags.md).
    private(set) var allowsNewAccounts: Bool?

    var isRunning: Bool { step != nil }

    var buttonLabel: String { step?.label ?? form.submitLabel }

    private let store: MailStore
    private let identity: ServerIdentity
    private let run: @MainActor (SettingsCommand) async -> CommandOutcome
    private let consent: any OAuthConsenting
    private let timing: Timing
    private var task: Task<Void, Never>?
    private var loginObservation: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "accountSetup")

    init(
        store: MailStore,
        identity: ServerIdentity,
        run: @escaping @MainActor (SettingsCommand) async -> CommandOutcome,
        consent: any OAuthConsenting,
        timing: Timing = Timing(),
        form: AccountSetupForm = AccountSetupForm()
    ) {
        self.store = store
        self.identity = identity
        self.run = run
        self.consent = consent
        self.timing = timing
        self.form = form
    }

    /// Reads the login's flags (allow-new-accounts, the OAuth URLs, the classification
    /// default) and keeps them current while the sheet is open.
    func start() {
        guard loginObservation == nil else { return }
        let observation = store.observeLogin(for: identity)
        loginObservation = Task { [weak self] in
            do {
                for try await login in observation {
                    self?.apply(login: login)
                }
            } catch {
                Self.logger.error("login observation ended")
            }
        }
    }

    func stop() {
        loginObservation?.cancel()
        loginObservation = nil
    }

    func apply(login: LoginRecord?) {
        allowsNewAccounts = login?.allowNewAccounts
        form.googleOAuthURL = login?.googleOauthUrl
        form.microsoftOAuthURL = login?.microsoftOauthUrl
        if !isRunning, form.accountName.isEmpty, form.emailAddress.isEmpty,
            let classification = login?.importanceClassificationDefault
        {
            form.classificationEnabled = classification
        }
    }

    // MARK: - Running

    func submit() {
        guard !isRunning, form.canSubmit else { return }
        task = Task { await self.runFlow() }
    }

    /// Cancel, or the sheet closing: stops the flow; a temporary OAuth account is deleted by
    /// the flow itself as it unwinds.
    func cancel() {
        task?.cancel()
    }

    /// Awaits the flow `submit()` started — for tests.
    func finish() async {
        await task?.value
    }

    private func runFlow() async {
        feedback = nil
        steps = []
        defer { step = nil }

        if form.mode == .auto {
            guard await detectConfiguration() else { return }
        }
        if form.isMissingPassword {
            feedback = .passwordRequired
            return
        }

        advance(.testingAuthentication)
        let before = Set((try? await store.accounts(identity: identity))?.map(\.id) ?? [])
        let outcome = await run(.createAccount(form.request))
        if case .failure(let error) = outcome {
            feedback = AccountSetupFeedback(error)
            return
        }
        guard let accountId = await newAccountId(excluding: before) else {
            Self.logger.error("created account not found in the mirror")
            feedback = .generic
            return
        }

        if form.usesOAuth, let provider = form.provider {
            advance(.awaitingConsent)
            feedback = .linkProvider(provider)
            guard await obtainConsent(accountId: accountId) else {
                // Clean up the temporary account before reporting, as the web client does.
                // Its own task: on Cancel this flow's task is cancelled, and the request
                // would inherit that and never leave.
                await Task { [self] in _ = await self.run(.deleteAccount(accountId: accountId)) }.value
                feedback = .consentAborted
                return
            }
            feedback = nil
        }

        advance(.loadingAccount)
        await waitForMailboxes(accountId: accountId)
        createdAccountId = accountId
    }

    private func advance(_ next: Step) {
        step = next
        steps.append(next)
    }

    // MARK: - Discovery

    /// ISPDB for the domain → MX → ISPDB for the MX host's last two labels → port probe on
    /// the first MX host. Whatever is found goes into the Manual fields. False stops the
    /// flow with the feedback set.
    private func detectConfiguration() async -> Bool {
        advance(.lookingUp)
        let email = form.emailAddress
        switch await ispdb(host: form.emailDomain, email: email) {
        case .failure(let error):
            feedback = AccountSetupFeedback(error)
            return false
        case .success(let found?):
            form.apply(found)
            return true
        case .success(nil):
            break
        }

        if case .failure(let error) = await run(.lookupMX(email: email)) {
            // The web client's `queryMx` throwing lands in the same catch as everything else.
            feedback = AccountSetupFeedback(error)
            return false
        }
        let hosts = await mxHosts(email: email)
        if let first = hosts.first {
            // The web client's last-two-labels rule, kept for parity: it breaks `.co.uk`.
            let domain = first.split(separator: ".").suffix(2).joined(separator: ".").lowercased()
            switch await ispdb(host: domain, email: email) {
            case .failure(let error):
                feedback = AccountSetupFeedback(error)
                return false
            case .success(let found?):
                form.apply(found)
                return true
            case .success(nil):
                break
            }
        }

        advance(.checkingConnectivity)
        guard let host = hosts.first, let probed = await probe(host: host, email: email) else {
            feedback = .discoveryFailed
            return false
        }
        form.apply(probed)
        return true
    }

    private func ispdb(host: String, email: String) async -> Result<DiscoveredConfiguration?, MailError> {
        if case .failure(let error) = await run(.lookupISPDB(host: host, email: email)) { return .failure(error) }
        let key = SettingsCommands.autoconfigISPDBKey(host: host, email: email)
        guard case .ready(let data) = await payload(kind: SettingsCommands.autoconfigISPDBKind, key: key) else {
            return .success(nil)
        }
        let fields = data.objectValue ?? [:]
        let found = DiscoveredConfiguration(
            imap: Self.server(fields["imapConfig"]), smtp: Self.server(fields["smtpConfig"]))
        return .success(found.isEmpty ? nil : found)
    }

    private func mxHosts(email: String) async -> [String] {
        guard case .ready(let data) = await payload(kind: SettingsCommands.autoconfigMXKind, key: email),
            case .array(let hosts)? = data.objectValue?["hosts"]
        else { return [] }
        return hosts.compactMap {
            if case .string(let host) = $0 { return host }
            return nil
        }
    }

    /// The four ports at once; IMAP needs 993 open, SMTP 465 or 587 (first wins).
    private func probe(host: String, email: String) async -> DiscoveredConfiguration? {
        let ports = [993, 143, 465, 587]
        var open: Set<Int> = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in ports {
                // No `@MainActor in` on the child: that closure trips the region-based
                // isolation checker; `isOpen` is main-actor isolated and hops there itself.
                group.addTask {
                    (port, await self.isOpen(host: host, port: port))
                }
            }
            for await (port, ok) in group where ok { open.insert(port) }
        }
        guard open.contains(993), let smtpPort = [465, 587].first(where: open.contains) else { return nil }
        return DiscoveredConfiguration(
            imap: DiscoveredServer(username: email, host: host, port: 993, security: .ssl),
            smtp: DiscoveredServer(
                username: email, host: host, port: smtpPort, security: smtpPort == 465 ? .ssl : .tls)
        )
    }

    private func isOpen(host: String, port: Int) async -> Bool {
        let outcome = await run(.testConnectivity(host: host, port: port))
        guard outcome.isSuccess else { return false }
        let key = SettingsCommands.autoconfigTestKey(host: host, port: port)
        return await payload(kind: SettingsCommands.autoconfigTestKind, key: key)
            == .ready(.object(["ok": .bool(true)]))
    }

    private static func server(_ value: AnyJSON?) -> DiscoveredServer? {
        guard let fields = value?.objectValue,
            case .string(let host)? = fields["host"],
            case .int(let port)? = fields["port"]
        else { return nil }
        var username: String?
        if case .string(let name)? = fields["username"] { username = name }
        var security = AccountSetupForm.Security.ssl
        if case .string(let raw)? = fields["security"], let parsed = AccountSetupForm.Security(rawValue: raw) {
            security = parsed
        }
        return DiscoveredServer(username: username, host: host, port: port, security: security)
    }

    // MARK: - OAuth

    private func obtainConsent(accountId: Int64) async -> Bool {
        guard case .success = await run(.startOAuth(accountId: accountId)),
            case .ready(let data) = await payload(
                kind: SettingsCommands.oauthStateKind, key: String(accountId)),
            case .string(let state)? = data.objectValue?["state"],
            let url = form.oauthURL(state: state, email: form.emailAddress)
        else {
            Self.logger.error("could not mint the OAuth state")
            return false
        }
        let result = await consent.obtainConsent(at: url) { [weak self] in
            await self?.isConnected(accountId: accountId) ?? false
        }
        return result == .granted && !Task.isCancelled
    }

    /// The connection test's verdict, which turns true once the server holds a token.
    private func isConnected(accountId: Int64) async -> Bool {
        guard case .success = await run(.testConnection(accountId: accountId)) else { return false }
        let row = await payload(kind: SettingsCommands.connectionTestKind, key: String(accountId))
        return row == .ready(.object(["ok": .bool(true)]))
    }

    // MARK: - Store reads

    private func payload(kind: String, key: String) async -> ServerResultPayload? {
        guard let loginId = try? await store.ensureLogin(identity).id,
            let row = try? await store.serverResult(kind: kind, key: key, loginId: loginId)
        else { return nil }
        return try? ServerResultPayload(payloadJSON: row.payloadJSON)
    }

    /// The row `createAccount` wrote: this login's account that was not there before.
    private func newAccountId(excluding before: Set<Int64>) async -> Int64? {
        let accounts = (try? await store.accounts(identity: identity)) ?? []
        let fresh = accounts.filter { !before.contains($0.id) }
        return (fresh.first { $0.emailAddress == form.emailAddress } ?? fresh.max { $0.remoteId < $1.remoteId })?.id
    }

    private func waitForMailboxes(accountId: Int64) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timing.loadingTimeout
        while clock.now < deadline, !Task.isCancelled {
            if let mailboxes = try? await store.mailboxes(accountId: accountId), !mailboxes.isEmpty { return }
            try? await Task.sleep(for: timing.loadingPoll)
        }
    }
}
