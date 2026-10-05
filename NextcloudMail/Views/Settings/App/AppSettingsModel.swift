// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// Everything the §7 tabs show, observed from the mirror, and the two ways they write:
/// queued operations and online commands (ADR-0068).
///
/// Two scopes (ADR-0091). Switches are one setting for the whole window: read from the first
/// login (lowest id) and written to every login through ``MessageListPreferenceStore/write(_:_:)``,
/// the path WS-29's list preferences already take (ADR-0088). Lists that live on one server —
/// trusted senders, internal addresses, text blocks, S/MIME certificates — follow
/// ``selectedLoginId``, which the tabs offer as a picker when more than one login is signed in.
@MainActor
@Observable
final class AppSettingsModel {
    /// Every signed-in login, lowest id first, kept current as flags are rediscovered.
    private(set) var logins: [LoginRecord] = []
    /// The login whose server-scoped lists show; nil means the first.
    var selectedLoginId: Int64? {
        didSet { if selectedLoginId != oldValue { observeSelectedLogin() } }
    }
    private(set) var preferences = AppPreferences()
    private(set) var trustedSenders: [TrustedSenderRecord] = []
    private(set) var internalAddresses: [InternalAddressRecord] = []
    private(set) var textBlocks: [TextBlockRecord] = []
    /// Keyed by the block's local id.
    private(set) var textBlockShares: [Int64: [TextBlockShareRecord]] = [:]
    private(set) var certificates: [SmimeCertificateRow] = []
    /// Users and groups for the text block share search, as the server answered them.
    private(set) var sharees: [ShareeSuggestion] = []
    /// A queued write that could not even be recorded locally — shown once, inline, in the
    /// web's wording.
    var errorMessage: String?

    let listPreferences: MessageListPreferenceStore
    private let store: MailStore
    private let services: AppSettingsServices
    private var tasks: [Task<Void, Never>] = []
    private var loginTasks: [Task<Void, Never>] = []
    private var preferenceTasks: [Task<Void, Never>] = []
    private var selectedTasks: [Task<Void, Never>] = []
    private var shareeTask: Task<Void, Never>?
    private var preferenceLoginId: Int64?
    private var observedSelectedLoginId: Int64?
    private var preferenceValues: [String: String] = [:]

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "app-settings")

    init(store: MailStore, listPreferences: MessageListPreferenceStore, services: AppSettingsServices) {
        self.store = store
        self.listPreferences = listPreferences
        self.services = services
    }

    // MARK: - Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        listPreferences.start()
        let store = store
        tasks = [
            Task { [weak self] in
                do {
                    for try await _ in store.observeAccounts() {
                        let logins = try await store.logins().filter { $0.id != nil }.sorted {
                            ($0.id ?? 0) < ($1.id ?? 0)
                        }
                        self?.apply(logins: logins)
                    }
                } catch {
                    Self.logger.error("login observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
        ]
    }

    func stop() {
        (tasks + loginTasks + preferenceTasks + selectedTasks).forEach { $0.cancel() }
        shareeTask?.cancel()
        tasks = []
        loginTasks = []
        preferenceTasks = []
        selectedTasks = []
        shareeTask = nil
        preferenceLoginId = nil
        observedSelectedLoginId = nil
        listPreferences.stop()
    }

    /// The login the server-scoped lists act on.
    var selectedLogin: LoginRecord? {
        logins.first { $0.id == selectedLoginId } ?? logins.first
    }

    var ownTextBlocks: [TextBlockRecord] { textBlocks.filter { !$0.isShared } }
    var sharedTextBlocks: [TextBlockRecord] { textBlocks.filter(\.isShared) }

    func shares(of block: TextBlockRecord) -> [TextBlockShareRecord] {
        guard let id = block.id else { return [] }
        return TextBlockFormatting.sortedShares(textBlockShares[id] ?? [])
    }

    /// A nil flag is not yet discovered and counts as available (server-flags.md).
    var followUpAvailable: Bool { logins.contains { $0.llmFollowupAvailable != false } }
    var contextChatAvailable: Bool { logins.contains { $0.contextChatAvailable != false } }

    private func apply(logins newLogins: [LoginRecord]) {
        let identitiesChanged = newLogins.map(\.identity) != logins.map(\.identity)
        logins = newLogins
        if identitiesChanged {
            loginTasks.forEach { $0.cancel() }
            loginTasks = newLogins.map { login in
                observe(store.observeLogin(for: login.identity)) { model, fresh in
                    guard let fresh, let index = model.logins.firstIndex(where: { $0.id == fresh.id }) else { return }
                    if model.logins[index] != fresh { model.logins[index] = fresh }
                }
            }
        }
        observePreferences(loginId: newLogins.first?.id)
        if let selectedLoginId, !newLogins.contains(where: { $0.id == selectedLoginId }) {
            self.selectedLoginId = nil
        }
        observeSelectedLogin()
    }

    private func observePreferences(loginId: Int64?) {
        guard loginId != preferenceLoginId else { return }
        preferenceLoginId = loginId
        preferenceTasks.forEach { $0.cancel() }
        preferenceTasks = []
        preferenceValues = [:]
        preferences = AppPreferences()
        guard let loginId else { return }
        preferenceTasks = AppPreferences.keys.map { key in
            observe(store.observePreferenceValue(key: key, loginId: loginId)) { model, value in
                model.preferenceValues[key] = value
                let parsed = AppPreferences(values: model.preferenceValues)
                if parsed != model.preferences { model.preferences = parsed }
            }
        }
    }

    private func observeSelectedLogin() {
        let loginId = selectedLogin?.id
        guard loginId != observedSelectedLoginId else { return }
        observedSelectedLoginId = loginId
        selectedTasks.forEach { $0.cancel() }
        shareeTask?.cancel()
        trustedSenders = []
        internalAddresses = []
        textBlocks = []
        textBlockShares = [:]
        certificates = []
        sharees = []
        guard let loginId else {
            selectedTasks = []
            return
        }
        selectedTasks = [
            observe(store.observeTrustedSenders(loginId: loginId)) { $0.trustedSenders = $1 },
            observe(store.observeInternalAddresses(loginId: loginId)) {
                $0.internalAddresses = InternalAddressInput.sorted($1)
            },
            observe(store.observeTextBlocks(loginId: loginId)) { $0.textBlocks = $1 },
            observe(store.observeTextBlockShares(loginId: loginId)) { $0.textBlockShares = $1 },
            observe(store.observeSmimeCertificates(loginId: loginId)) {
                $0.certificates = $1.map(SmimeCertificateRow.init)
            },
        ]
    }

    private func observe<Element: Sendable>(
        _ sequence: StoreObservation<Element>,
        _ apply: @escaping @MainActor (AppSettingsModel, Element) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await value in sequence {
                    guard let self, !Task.isCancelled else { return }
                    apply(self, value)
                }
            } catch {
                Self.logger.error("observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Preferences (every login)

    /// Queues `key = value` for every login. The control reads the mirrored row back, so a
    /// failure leaves it where it was, with the web's message under it.
    func setPreference(_ key: String, _ value: String) async {
        guard await listPreferences.write(key, value) else {
            errorMessage = String(localized: "Could not update preference")
            return
        }
    }

    func setBool(_ key: String, _ value: Bool) async {
        await setPreference(key, value ? "true" : "false")
    }

    /// The server's preference and the reader's local delay, in one action: opening a
    /// message follows the new choice at once, before the queued write reaches the server.
    func setAutoMarkAsRead(_ value: AutoMarkAsRead) async {
        await setPreference(AppPreferences.autoMarkAsReadKey, value.rawValue)
        do {
            try await store.setMetaValue(value.localDelay.metaValue, forKey: MarkAsReadDelay.metaKey)
        } catch {
            Self.logger.error(
                "could not store the local mark-as-read delay: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Server-scoped lists (selected login)

    /// Queues one operation for the selected login, through its lowest-id account's queue.
    /// False, with ``errorMessage`` set to `failure`, when it could not be queued.
    @discardableResult
    func perform(_ operation: MailOperation, failure: String) async -> Bool {
        do {
            guard let login = selectedLogin, let loginId = login.id,
                let accountId = try await store.accounts(identity: login.identity).map(\.id).min(),
                let queue = services.queue(accountId)
            else { throw AccountSettingsServiceError.loginNotRunning }
            try await queue.perform(operation, loginId: loginId)
            return true
        } catch {
            Self.logger.error("could not queue a settings write: \(String(describing: error), privacy: .public)")
            errorMessage = failure
            return false
        }
    }

    func removeTrustedSender(_ sender: TrustedSenderRecord) async {
        let operation: MailOperation =
            sender.type == "domain"
            ? .trustDomain(domain: sender.email, trusted: false)
            : .trustSender(email: sender.email, trusted: false)
        await perform(
            operation,
            failure: String(format: String(localized: "Could not remove trusted sender %@"), sender.email))
    }

    /// False when the input is not an address or a domain; the sheet keeps it then.
    @discardableResult
    func addInternalAddress(_ raw: String) async -> Bool {
        guard let parsed = InternalAddressInput.parse(raw) else { return false }
        return await perform(
            .addInternalAddress(address: parsed.address, type: parsed.type),
            failure: String(format: String(localized: "Could not add internal address %@"), parsed.address))
    }

    func removeInternalAddress(_ record: InternalAddressRecord) async {
        await perform(
            .removeInternalAddress(address: record.address, type: record.type),
            failure: String(format: String(localized: "Could not remove internal address %@"), record.address))
    }

    // MARK: - Text blocks

    @discardableResult
    func createTextBlock(title: String, content: String) async -> Bool {
        await perform(
            .createTextBlock(title: title, content: content),
            failure: String(localized: "Could not save text block"))
    }

    @discardableResult
    func updateTextBlock(_ block: TextBlockRecord, title: String, content: String) async -> Bool {
        await perform(
            .updateTextBlock(textBlockRemoteId: block.remoteId, title: title, content: content),
            failure: String(localized: "Could not save text block"))
    }

    func deleteTextBlock(_ block: TextBlockRecord) async {
        await perform(
            .deleteTextBlock(textBlockRemoteId: block.remoteId),
            failure: String(localized: "Could not delete text block"))
    }

    @discardableResult
    func share(_ block: TextBlockRecord, with sharee: ShareeSuggestion) async -> Bool {
        await perform(
            .shareTextBlock(textBlockRemoteId: block.remoteId, shareWith: sharee.shareWith, type: sharee.type),
            failure: String(format: String(localized: "Could not share text block with %@"), sharee.displayName))
    }

    @discardableResult
    func unshare(_ block: TextBlockRecord, share: TextBlockShareRecord) async -> Bool {
        await perform(
            .unshareTextBlock(textBlockRemoteId: block.remoteId, shareWith: share.shareWith),
            failure: String(format: String(localized: "Could not delete share for %@"), share.shareWith))
    }

    /// Debounced like the web's sharee search; the answer arrives as a `serverResult` row.
    func searchSharees(_ term: String, for block: TextBlockRecord?) {
        shareeTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let login = selectedLogin, let loginId = login.id else {
            sharees = []
            return
        }
        let excluding = Set(block.map { shares(of: $0).map(\.shareWith) } ?? [])
        let store = store
        shareeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            services.searchSharees(login, trimmed)
            do {
                for try await row in store.observeServerResult(
                    kind: ServerResultKind.sharees.rawValue, key: trimmed, loginId: loginId)
                {
                    guard !Task.isCancelled else { return }
                    sharees = ShareeSuggestion.suggestions(
                        from: Self.payload(row), excluding: excluding, selfUserId: login.loginName)
                }
            } catch {
                Self.logger.error("sharee observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func clearSharees() {
        shareeTask?.cancel()
        shareeTask = nil
        sharees = []
    }

    nonisolated static func payload(_ row: ServerResultRecord?) -> AnyJSON? {
        guard let row, case .ready(let data)? = try? ServerResultPayload(payloadJSON: row.payloadJSON) else {
            return nil
        }
        return data
    }

    // MARK: - S/MIME (commands)

    /// Converts the PKCS #12 file on this Mac, then uploads the PEM pair. The password goes
    /// into ``SmimeCertificateConverter`` and nowhere else.
    func importPKCS12(_ data: Data, password: String) async -> SmimeImportResult {
        let pair: SmimeCertificateConverter.PEMPair
        do {
            pair = try SmimeCertificateConverter.pemPair(fromPKCS12: data, password: password)
        } catch {
            return .failed(error.message)
        }
        return await importPEM(certificate: pair.certificate, privateKey: pair.privateKey)
    }

    func importPEM(certificate: Data, privateKey: Data?) async -> SmimeImportResult {
        guard let login = selectedLogin else {
            return .failed(String(localized: "Failed to import the certificate"))
        }
        let outcome = await services.run(login, .importSMIME(pem: certificate, privateKey: privateKey))
        return SmimeImportResult(outcome, hadPrivateKey: privateKey != nil)
    }

    /// Nil on success, else the message to show.
    func deleteCertificate(_ row: SmimeCertificateRow) async -> String? {
        guard let login = selectedLogin else { return String(localized: "Failed to delete the certificate") }
        let outcome = await services.run(login, .deleteSMIME(certificateRemoteId: row.remoteId))
        return outcome.isSuccess ? nil : String(localized: "Failed to delete the certificate")
    }
}

/// What the import step shows, in the web's wording (`SmimeCertificateModal.vue`).
enum SmimeImportResult: Equatable {
    case imported
    case failed(String)

    /// The web's rule (`SmimeCertificateModal.vue`): any failed upload that carried a key
    /// blames the key. The server answers a mismatched or passphrase-protected key with a
    /// 500 `ServiceException` ("Private key does not match certificate or is protected by a
    /// passphrase"), the same status as an unparseable certificate, so the status cannot
    /// tell them apart anyway.
    init(_ outcome: CommandOutcome, hadPrivateKey: Bool) {
        switch outcome {
        case .success:
            self = .imported
        case .failure where hadPrivateKey:
            self = .failed(
                String(
                    localized:
                        "Failed to import the certificate. Please make sure that the private key matches the certificate and is not protected by a passphrase."
                ))
        case .failure:
            self = .failed(String(localized: "Failed to import the certificate"))
        }
    }

    var message: String {
        switch self {
        case .imported: String(localized: "Certificate imported successfully")
        case .failed(let message): message
        }
    }
}
