// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// Everything one account's settings show, observed from the mirror, and the two ways they
/// write: queued operations and online commands (ADR-0068).
///
/// Nothing here renders a response. A command's outcome says whether to show a spinner or
/// an error; what changed arrives through the same observations as every other row.
@MainActor
@Observable
final class AccountSettingsModel {
    let accountId: Int64

    private(set) var account: AccountRecord?
    private(set) var aliases: [AliasRecord] = []
    private(set) var sieve: SieveStateRecord?
    private(set) var quickActions: [QuickActionRecord] = []
    /// Keyed by the quick action's local id, each in step order.
    private(set) var quickActionSteps: [Int64: [QuickActionStepRecord]] = [:]
    private(set) var delegations: [DelegationRecord] = []
    private(set) var mailboxes: [MailboxRecord] = []
    private(set) var tags: [TagRecord] = []
    private(set) var login: LoginRecord?
    private(set) var certificates: [SmimeCertificateRecord] = []
    /// The last connection test's verdict, nil until one ran.
    private(set) var connectionOK: Bool?
    /// User sharees for the delegation search term, as the server answered them.
    private(set) var sharees: [Sharee] = []
    /// A queued write that could not even be recorded locally — shown once, inline.
    var queueError: String?

    struct Sharee: Identifiable, Equatable, Sendable {
        let userId: String
        let displayName: String
        var id: String { userId }
    }

    private let store: MailStore
    private let services: AccountSettingsServices
    private var tasks: [Task<Void, Never>] = []
    private var loginTasks: [Task<Void, Never>] = []
    private var shareeTask: Task<Void, Never>?
    private var observedLoginId: Int64?

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "account-settings")

    init(accountId: Int64, store: MailStore, services: AccountSettingsServices) {
        self.accountId = accountId
        self.store = store
        self.services = services
    }

    // MARK: - Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        let store = store
        let accountId = accountId
        tasks = [
            observe(store.observeAccounts()) { model, accounts in
                model.apply(account: accounts.first { $0.id == accountId })
            },
            observe(store.observeAliases(accountId: accountId)) { $0.aliases = $1 },
            observe(store.observeSieveState(accountId: accountId)) { $0.sieve = $1 },
            observe(store.observeQuickActions(accountId: accountId)) { $0.quickActions = $1 },
            observe(store.observeQuickActionSteps(accountId: accountId)) { $0.quickActionSteps = $1 },
            observe(store.observeDelegations(accountId: accountId)) { $0.delegations = $1 },
            observe(store.observeMailboxes(accountId: accountId)) { $0.mailboxes = $1 },
            observe(store.observeTags(accountId: accountId)) { $0.tags = $1 },
        ]
    }

    func stop() {
        (tasks + loginTasks).forEach { $0.cancel() }
        shareeTask?.cancel()
        tasks = []
        loginTasks = []
        shareeTask = nil
        observedLoginId = nil
    }

    private func apply(account: AccountRecord?) {
        let identityChanged = self.account?.identity != account?.identity
        self.account = account
        guard identityChanged, let account else { return }
        loginTasks.forEach { $0.cancel() }
        loginTasks = [
            observe(store.observeLogin(for: account.identity)) { model, login in
                model.login = login
                model.observeLoginScoped(login?.id)
            }
        ]
    }

    /// The login-scoped rows: certificates and the connection-test verdict.
    private func observeLoginScoped(_ loginId: Int64?) {
        guard let loginId, loginId != observedLoginId else { return }
        observedLoginId = loginId
        loginTasks.append(observe(store.observeSmimeCertificates(loginId: loginId)) { $0.certificates = $1 })
        loginTasks.append(
            observe(
                store.observeServerResult(
                    kind: SettingsCommands.connectionTestKind, key: String(accountId), loginId: loginId)
            ) { model, row in
                model.connectionOK = row.flatMap(Self.connectionVerdict)
            })
    }

    private func observe<Element: Sendable>(
        _ sequence: StoreObservation<Element>,
        _ apply: @escaping @MainActor (AccountSettingsModel, Element) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await value in sequence {
                    guard let self else { return }
                    apply(self, value)
                }
            } catch {
                Self.logger.error("observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated static func connectionVerdict(_ row: ServerResultRecord) -> Bool? {
        guard case .ready(let data)? = try? ServerResultPayload(payloadJSON: row.payloadJSON),
            case .bool(let ok)? = data.objectValue?["ok"]
        else { return nil }
        return ok
    }

    // MARK: - Derived

    var sections: [AccountSettingsSection] {
        account.map(AccountSettingsSection.visible(for:)) ?? []
    }

    /// The mirror's filters, nil until the Sieve row has them.
    var filters: [MailFilterDraft]? {
        MailFilterDraft.parse(sieve?.filtersJSON)
    }

    func steps(of action: QuickActionRecord) -> [QuickActionStepRecord] {
        action.id.flatMap { quickActionSteps[$0] } ?? []
    }

    /// The local mailbox a server mailbox id names, for the pickers.
    func localMailboxId(remote: Int64?) -> Int64? {
        guard let remote else { return nil }
        return mailboxes.first { $0.remoteId == remote }?.id
    }

    func remoteMailboxId(local: Int64?) -> Int64? {
        guard let local else { return nil }
        return mailboxes.first { $0.id == local }?.remoteId
    }

    /// A filter's "Move into folder" names the folder by its IMAP path.
    func mailboxPath(local: Int64?) -> String? {
        guard let local else { return nil }
        return mailboxes.first { $0.id == local }?.name
    }

    func localMailboxId(path: String) -> Int64? {
        mailboxes.first { $0.name == path }?.id
    }

    // MARK: - Queued writes

    /// Applies one operation locally and queues it. A failure here is local (the account is
    /// gone from the mirror); a server refusal later surfaces in the status footer.
    @discardableResult
    func perform(_ operation: MailOperation) async -> Bool {
        guard let queue = services.queue(accountId) else {
            queueError = String(localized: "The change could not be saved.")
            return false
        }
        do {
            try await queue.perform(operation, accountId: accountId)
            return true
        } catch {
            Self.logger.error("enqueue failed: \(String(describing: error), privacy: .public)")
            queueError = String(localized: "The change could not be saved.")
            return false
        }
    }

    func patch(_ patch: AccountPatch) async {
        await perform(.patchAccount(patch))
    }

    /// A default folder, given the picker's local mailbox id.
    func setDefaultFolder(_ role: DefaultFolder, localMailboxId: Int64?) async {
        guard let localMailboxId else { return }
        var patch = AccountPatch()
        switch role {
        case .drafts: patch.draftsMailboxId = localMailboxId
        case .sent: patch.sentMailboxId = localMailboxId
        case .trash: patch.trashMailboxId = localMailboxId
        case .archive: patch.archiveMailboxId = localMailboxId
        case .snooze: patch.snoozeMailboxId = localMailboxId
        case .junk: patch.junkMailboxId = localMailboxId
        }
        await self.patch(patch)
    }

    /// Saves a quick action and its steps, all queued. A new action's steps name its
    /// placeholder id, which the drain swaps for the server's (ADR-0081).
    @discardableResult
    func save(_ draft: QuickActionDraft, original: QuickActionDraft?) async -> Bool {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        var remoteId = draft.remoteId
        if let existing = remoteId {
            if original?.name != name {
                guard await perform(.updateQuickAction(quickActionRemoteId: existing, name: name)) else { return false }
            }
        } else {
            let before = Set(((try? await store.quickActions(accountId: accountId)) ?? []).map(\.remoteId))
            guard await perform(.createQuickAction(name: name)) else { return false }
            let after = (try? await store.quickActions(accountId: accountId)) ?? []
            remoteId = after.first { !before.contains($0.remoteId) }?.remoteId
        }
        guard let remoteId else {
            queueError = String(localized: "Failed to create quick action")
            return false
        }
        for (step, order) in draft.stepWrites(comparedTo: original) {
            let intent = ActionStepIntent(
                quickActionRemoteId: remoteId,
                stepRemoteId: step.remoteId,
                name: step.name,
                order: order,
                tagRemoteId: step.name == QuickActionStep.applyTag ? step.tagRemoteId : nil,
                mailboxRemoteId: step.name == QuickActionStep.moveThread ? step.mailboxRemoteId : nil
            )
            guard await perform(.upsertActionStep(intent)) else { return false }
        }
        return true
    }

    /// The web deletes a saved step as soon as its ✕ is pressed.
    func deleteStep(_ step: QuickActionDraft.Step, of quickActionRemoteId: Int64?) async {
        guard let quickActionRemoteId, let stepRemoteId = step.remoteId else { return }
        await perform(.deleteActionStep(quickActionRemoteId: quickActionRemoteId, stepRemoteId: stepRemoteId))
    }

    // MARK: - Commands

    func run(_ command: SettingsCommand) async -> CommandOutcome {
        guard let account else { return .failure(.notFound) }
        return await services.run(account, command)
    }

    func saveFilters(_ filters: [MailFilterDraft]) async -> CommandOutcome {
        await run(.saveFilters(accountId: accountId, filters: filters.map(\.json)))
    }

    // MARK: - Delegate search

    /// Debounced 300 ms, as the web; the answer arrives as a `serverResult` row.
    func searchDelegates(_ term: String) {
        shareeTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let account, let loginId = login?.id else {
            sharees = []
            return
        }
        shareeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            services.searchSharees(account, trimmed)
            do {
                for try await row in store.observeServerResult(
                    kind: ServerResultKind.sharees.rawValue, key: trimmed, loginId: loginId)
                {
                    guard !Task.isCancelled else { return }
                    sharees = Self.users(in: row, excluding: Set(delegations.map(\.userId) + [account.loginName]))
                }
            } catch {
                Self.logger.error("sharee observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// User sharees only (a group cannot be a delegate), without yourself or anyone already
    /// delegated.
    nonisolated static func users(in row: ServerResultRecord?, excluding: Set<String>) -> [Sharee] {
        guard let row, case .ready(.array(let items))? = try? ServerResultPayload(payloadJSON: row.payloadJSON) else {
            return []
        }
        return items.compactMap { item in
            guard let fields = item.objectValue, fields["type"]?.stringValue == "user",
                let userId = fields["shareWith"]?.stringValue, !excluding.contains(userId)
            else { return nil }
            return Sharee(userId: userId, displayName: fields["displayName"]?.stringValue ?? userId)
        }
    }
}

/// The six special folders §8.3's Default folders section assigns.
enum DefaultFolder: CaseIterable, Identifiable, Sendable {
    case drafts
    case sent
    case trash
    case archive
    case snooze
    case junk

    var id: Self { self }

    var title: String {
        switch self {
        case .drafts: String(localized: "Drafts")
        case .sent: String(localized: "Sent")
        case .trash: String(localized: "Deleted")
        case .archive: String(localized: "Archived")
        case .snooze: String(localized: "Snoozed")
        case .junk: String(localized: "Junk")
        }
    }

    /// The server's mailbox id the account row holds for this role.
    func remoteId(in account: AccountRecord) -> Int64? {
        switch self {
        case .drafts: account.draftsMailboxId
        case .sent: account.sentMailboxId
        case .trash: account.trashMailboxId
        case .archive: account.archiveMailboxId
        case .snooze: account.snoozeMailboxId
        case .junk: account.junkMailboxId
        }
    }
}
