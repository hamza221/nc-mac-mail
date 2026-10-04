// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// The sidebar's accounts, mailbox trees, virtual entries and menus, live.
///
/// Observation, one layer per thing the sidebar draws: `store.observeAccounts()` says which
/// accounts exist; per account, its mailboxes, its quota row and its connection-test row; and
/// the outbox, for the Outbox entry. `MailboxTree.layout(accounts:outboxCount:)` turns all of
/// it into what the view draws -- a pure function, run again whenever an input changes.
///
/// Nothing here reaches the network. Reads come from `MailStore`; the menus write through
/// ``SidebarServices`` -- the mutation queue for every folder change, and the three
/// online-only commands (remove account, repair, delegation) whose outcome is the only thing
/// awaited ([ADR-0068](../../../docs/decisions/0068-settings-commands.md)).
@MainActor
@Observable
final class SidebarStore {
    private(set) var accounts: [AccountRecord] = []
    private(set) var mailboxNodes: [Int64: [MailboxNode]] = [:]
    /// Every row of each account, unfiltered: the move picker and drop checks read these.
    private(set) var mailboxRows: [Int64: [MailboxTreeRow]] = [:]
    /// What the view draws, rebuilt from the inputs above whenever one changes.
    private(set) var layout = SidebarLayout(virtualEntries: [.priorityInbox], accounts: [], outboxCount: nil)
    /// Node ids the user collapsed, per account. Absence means expanded, which is the
    /// sidebar's default shape ([ux-spec.md](../../../docs/product/ux-spec.md#sidebar)).
    private(set) var collapsedNodeIDs: [Int64: Set<String>] = [:]
    /// Accounts whose "Show all folders" is on. Absent means collapsed, the web's default.
    private(set) var showsAllFolders: Set<Int64> = []
    /// Accounts expanded only while a drag hovers over them; never persisted.
    private(set) var dragExpanded: Set<Int64> = []
    private(set) var outboxCount = 0
    private(set) var quotas: [Int64: Quota] = [:]
    /// The latest connection test per account; absent until one ran.
    private(set) var connectionOK: [Int64: Bool] = [:]
    /// Folders whose Repair the server rate-limited, and until when.
    private(set) var repairBlockedUntil: [Int64: Date] = [:]

    /// The mailbox whose Get info panel is open, if any. Settable so the sheet's binding can
    /// clear it when the panel closes.
    var infoTarget: MailboxInfoTarget?
    /// The text prompt on screen: Add folder, Add subfolder, Rename.
    var prompt: SidebarPrompt?
    /// The destructive confirmation on screen.
    var confirmation: SidebarConfirmation?
    /// The folder the Move folder sheet is open for.
    var moveSource: MoveSource?
    /// The account the delegation sheet is open for.
    var delegationAccount: AccountRecord?
    /// An error to show in an alert: what failed, in the user's words.
    var alert: SidebarAlert?

    private let store: MailStore
    private let now: @MainActor () -> Date
    private var services: SidebarServices?
    private var accountsObservation: Task<Void, Never>?
    private var outboxObservation: Task<Void, Never>?
    private var accountTasks: [Int64: Task<Void, Never>] = [:]
    private var testedAccounts: Set<Int64> = []

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "sidebar")

    init(store: MailStore, now: @escaping @MainActor () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// The quota of one account, as the server reported it: bytes.
    struct Quota: Equatable {
        let usage: Int
        let limit: Int
    }

    struct MoveSource: Identifiable {
        let row: MailboxTreeRow
        let accountId: Int64
        var id: Int64 { row.id }
    }

    // MARK: - Lifecycle

    /// Starts observing. Safe to call more than once: a run already in progress is left alone.
    func start() {
        guard accountsObservation == nil else { return }
        accountsObservation = Task { [weak self] in
            guard let store = self?.store else { return }
            do {
                for try await fresh in store.observeAccounts() {
                    guard let self else { return }
                    apply(accounts: fresh)
                }
            } catch {
                Self.logger.error("account observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
        outboxObservation = Task { [weak self] in
            guard let store = self?.store else { return }
            do {
                for try await messages in store.observeOutboxMessages() {
                    guard let self else { return }
                    outboxCount = messages.count
                    rebuildLayout()
                }
            } catch {
                Self.logger.error("outbox observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The view calls this when the column goes away. Cancelling every task is enough --
    /// dropping the iterator terminates the store's sequence, which terminates the database
    /// observation with it ([ADR-0034](../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)).
    func stop() {
        accountsObservation?.cancel()
        accountsObservation = nil
        outboxObservation?.cancel()
        outboxObservation = nil
        for task in accountTasks.values { task.cancel() }
        accountTasks.removeAll()
    }

    /// Hands the store its engines. The view does this from the environment once it has the
    /// `AppSession`; until then the menus are inert and nothing is requested. Each account's
    /// quota is asked for and its connection tested once per launch, as the web client does
    /// at load (§2.1).
    func attach(_ services: SidebarServices) {
        self.services = services
        for account in accounts { checkAccount(account) }
    }

    private func checkAccount(_ account: AccountRecord) {
        guard let services, !testedAccounts.contains(account.id) else { return }
        testedAccounts.insert(account.id)
        services.requestQuota(account)
        Task { _ = await services.run(account, .testConnection(accountId: account.id)) }
    }

    private func apply(accounts fresh: [AccountRecord]) {
        accounts = fresh
        let freshIDs = Set(fresh.map(\.id))
        for (accountId, task) in accountTasks where !freshIDs.contains(accountId) {
            task.cancel()
            accountTasks[accountId] = nil
            mailboxNodes[accountId] = nil
            mailboxRows[accountId] = nil
            collapsedNodeIDs[accountId] = nil
            quotas[accountId] = nil
            connectionOK[accountId] = nil
        }
        for account in fresh where accountTasks[account.id] == nil {
            let identity = account.identity
            let accountId = account.id
            accountTasks[account.id] = Task { [weak self] in
                await self?.loadPersistedState(accountId: accountId)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self?.observeMailboxes(accountId: accountId) }
                    group.addTask { await self?.observeServerRows(accountId: accountId, identity: identity) }
                }
            }
            checkAccount(account)
        }
        rebuildLayout()
    }

    private func observeMailboxes(accountId: Int64) async {
        do {
            for try await records in store.observeMailboxes(accountId: accountId) {
                // Cancelling this account's task races the row's own cascade-deleted mailboxes
                // firing an empty page through this same loop: cancellation is cooperative, so
                // an iteration already resumed with a value can still run after `apply(accounts:)`
                // has removed this id. Re-checking against the current, authoritative `accounts`
                // right before the write -- rather than trusting why this task started -- is
                // what keeps a removed account's entry from reappearing as an empty array.
                guard accounts.contains(where: { $0.id == accountId }) else { return }
                let rows = records.map(\.treeRow)
                mailboxRows[accountId] = rows
                mailboxNodes[accountId] = MailboxTree.build(from: rows)
                rebuildLayout()
            }
        } catch {
            Self.logger.error(
                "mailbox observation stopped for account \(accountId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The quota and connection-test rows. Both are keyed by the login, which a just-added
    /// account may not have yet; without one there is nothing to observe and the menu simply
    /// shows no quota.
    private func observeServerRows(accountId: Int64, identity: ServerIdentity) async {
        guard let loginId = try? await store.login(for: identity)?.id else { return }
        let key = ServerResultKind.accountKey(accountId)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self, store] in
                do {
                    for try await row in store.observeServerResult(
                        kind: ServerResultKind.quota.rawValue, key: key, loginId: loginId)
                    {
                        await self?.apply(quotaRow: row, accountId: accountId)
                    }
                } catch {
                    Self.logger.error("quota observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
            group.addTask { [weak self, store] in
                do {
                    for try await row in store.observeServerResult(
                        kind: SettingsCommands.connectionTestKind, key: key, loginId: loginId)
                    {
                        await self?.apply(connectionRow: row, accountId: accountId)
                    }
                } catch {
                    Self.logger.error("test observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func apply(quotaRow row: ServerResultRecord?, accountId: Int64) {
        guard
            let row, let payload = try? ServerResultPayload(payloadJSON: row.payloadJSON),
            case .ready(let json) = payload, let object = json.objectValue,
            case .int(let usage) = object["usage"], case .int(let limit) = object["limit"]
        else { return }
        quotas[accountId] = Quota(usage: usage, limit: limit)
    }

    private func apply(connectionRow row: ServerResultRecord?, accountId: Int64) {
        guard
            let row, let payload = try? ServerResultPayload(payloadJSON: row.payloadJSON),
            case .ready(let json) = payload, case .bool(let ok) = json.objectValue?["ok"]
        else { return }
        connectionOK[accountId] = ok
        rebuildLayout()
    }

    private func rebuildLayout() {
        let inputs = accounts.map { account in
            SidebarAccountInput(
                accountId: account.id,
                rows: mailboxRows[account.id] ?? [],
                showSubscribedOnly: account.showSubscribedOnly,
                pinnedRemoteIds: Set(
                    [account.draftsMailboxId, account.sentMailboxId, account.trashMailboxId].compactMap { $0 }),
                showsAllFolders: showsAllFolders.contains(account.id) || dragExpanded.contains(account.id),
                isDisabled: isDisabled(account)
            )
        }
        let fresh = MailboxTree.layout(accounts: inputs, outboxCount: outboxCount)
        if fresh != layout { layout = fresh }
    }

    // MARK: - Account state

    /// A provisioned account whose connection test failed: its credentials are the server's,
    /// so there is nothing the user can fix here (ADR-0086).
    func isDisabled(_ account: AccountRecord) -> Bool {
        account.provisioningId != nil && connectionOK[account.id] == false
    }

    /// Any other account whose connection test failed: the "Connection failed" row.
    func hasConnectionError(_ account: AccountRecord) -> Bool {
        account.provisioningId == nil && connectionOK[account.id] == false
    }

    func canDelegate(_ account: AccountRecord) -> Bool {
        !account.isDelegated && account.provisioningId == nil
    }

    func canRemove(_ account: AccountRecord) -> Bool {
        account.provisioningId == nil && !account.isDelegated
    }

    /// "Used quota: 42 % (10 GB)", "Used quota: 42 %", or nil -- the web client's
    /// `quotaText`, with a zero limit (no quota set) treated as no answer rather than ∞ %.
    func quotaText(for account: AccountRecord) -> String? {
        if let quota = quotas[account.id], quota.limit > 0 {
            let percent = Int((Double(quota.usage) / Double(quota.limit) * 100).rounded(.up))
            let limit = ByteCountFormatter.string(fromByteCount: Int64(quota.limit), countStyle: .file)
            return String(localized: "Used quota: \(percent)% (\(limit))")
        }
        if let percentage = account.quotaPercentage, percentage > 0 {
            return String(localized: "Used quota: \(percentage)%")
        }
        return nil
    }

    // MARK: - Expansion

    func isExpanded(accountId: Int64, node: MailboxNode) -> Bool {
        !(collapsedNodeIDs[accountId]?.contains(node.id) ?? false)
    }

    func setExpanded(_ expanded: Bool, accountId: Int64, node: MailboxNode) {
        var collapsed = collapsedNodeIDs[accountId] ?? []
        if expanded {
            collapsed.remove(node.id)
        } else {
            collapsed.insert(node.id)
        }
        collapsedNodeIDs[accountId] = collapsed
        persistCollapsedNodeIDs(collapsed, accountId: accountId)
    }

    /// "Show all folders" / "Collapse folders".
    func setShowsAllFolders(_ shows: Bool, accountId: Int64) {
        if shows {
            showsAllFolders.insert(accountId)
        } else {
            showsAllFolders.remove(accountId)
        }
        dragExpanded.remove(accountId)
        rebuildLayout()
        Task { [store] in
            try? await store.setMetaValue(shows ? "1" : nil, forKey: Self.showAllKey(accountId: accountId))
        }
    }

    /// A drag hovering over the account's "Show all folders" row opens it for the drag
    /// (§3.4); ``endDrag()`` puts it back.
    func expandForDrag(accountId: Int64) {
        guard !showsAllFolders.contains(accountId), !dragExpanded.contains(accountId) else { return }
        dragExpanded.insert(accountId)
        rebuildLayout()
    }

    func endDrag() {
        guard !dragExpanded.isEmpty else { return }
        dragExpanded.removeAll()
        rebuildLayout()
    }

    /// One `meta` row per account holding every collapsed node's id, rather than one row per
    /// mailbox: a 200-mailbox account would otherwise mean 200 point reads before the first
    /// frame, and expansion is the kind of state a single small JSON array already fits.
    private static func collapsedKey(accountId: Int64) -> String { "sidebar.collapsedNodeIDs.\(accountId)" }
    private static func showAllKey(accountId: Int64) -> String { "sidebar.showAllFolders.\(accountId)" }

    private func loadPersistedState(accountId: Int64) async {
        if (try? await store.metaValue(forKey: Self.showAllKey(accountId: accountId))) == "1" {
            showsAllFolders.insert(accountId)
            rebuildLayout()
        }
        guard
            let raw = try? await store.metaValue(forKey: Self.collapsedKey(accountId: accountId)),
            let data = raw.data(using: .utf8),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        collapsedNodeIDs[accountId] = Set(ids)
    }

    private func persistCollapsedNodeIDs(_ ids: Set<String>, accountId: Int64) {
        Task { [store] in
            let key = Self.collapsedKey(accountId: accountId)
            guard ids.isEmpty == false else {
                try? await store.setMetaValue(nil, forKey: key)
                return
            }
            guard let data = try? JSONEncoder().encode(Array(ids)), let json = String(data: data, encoding: .utf8)
            else { return }
            try? await store.setMetaValue(json, forKey: key)
        }
    }

    // MARK: - v1 actions

    // `refresh` is set by `RootSplitView`, which can reach the engine. `showStorage(_:)`,
    // `openAccountSettings(_:)` and `signOut(_:)` only choose the Settings tab; the *view*
    // opens the window with `@Environment(\.openSettings)`, because AppKit's
    // `showSettingsWindow:` selector no longer opens a SwiftUI `Settings` scene (ADR-0062).

    /// Syncs one mailbox, or every mailbox of the account when `mailboxId` is nil.
    var refresh: (@MainActor (_ accountId: Int64, _ mailboxId: Int64?) -> Void)?

    func refreshAccount(_ account: AccountRecord) {
        refresh?(account.id, nil)
        services?.requestQuota(account)
    }

    func showStorage(_ account: AccountRecord) {
        Self.logger.info("storage panel requested for account \(account.id, privacy: .public)")
        SettingsTab.preferredTab = .storage
    }

    func openAccountSettings(_ account: AccountRecord) {
        Self.logger.info("account settings requested for account \(account.id, privacy: .public)")
        SettingsTab.preferredAccountID = account.id
        SettingsTab.preferredTab = .accounts
    }

    /// The delegation sheet's list: the mirror's delegates, live (refreshed by the
    /// server-state mirror and by every delegate/revoke command).
    func observeDelegations(accountId: Int64) -> StoreObservation<[DelegationRecord]> {
        store.observeDelegations(accountId: accountId)
    }

    func signOut(_ account: AccountRecord) {
        Self.logger.info("sign-out requested for account \(account.id, privacy: .public)")
        SettingsTab.preferredTab = .accounts
    }

    func refreshMailbox(accountId: Int64, mailboxId: Int64) {
        refresh?(accountId, mailboxId)
    }

    /// Opens the Get info panel. The view presents on `infoTarget` and clears it on dismiss.
    func getInfo(accountId: Int64, mailboxId: Int64) {
        infoTarget = MailboxInfoTarget(accountId: accountId, mailboxId: mailboxId)
    }

    /// The panel's model, built here because this store is what holds the `MailStore`; the
    /// panel reads the mirror and nothing else.
    func infoModel(for target: MailboxInfoTarget) -> MailboxInfoModel {
        MailboxInfoModel(target: target, store: store)
    }

    // MARK: - Account menu (§3.2)

    func setShowSubscribedOnly(_ value: Bool, account: AccountRecord) async {
        await enqueue(.patchAccount(AccountPatch(showSubscribedOnly: value)), accountId: account.id, failure: nil)
    }

    /// Swaps the account with its neighbour and queues every account's new position, as the
    /// web client's `moveAccount` does -- only the ones whose position actually changed.
    func moveAccount(_ account: AccountRecord, up: Bool) async {
        var ordered = accounts
        guard let index = ordered.firstIndex(where: { $0.id == account.id }) else { return }
        let other = up ? index - 1 : index + 1
        guard ordered.indices.contains(other) else { return }
        ordered.swapAt(index, other)
        for (position, entry) in ordered.enumerated() where entry.sortOrder != position {
            await enqueue(.patchAccount(AccountPatch(order: position)), accountId: entry.id, failure: nil)
        }
    }

    /// Add folder: a top-level folder.
    func createFolder(named input: String, accountId: Int64) async {
        let delimiter = mailboxRows[accountId]?.compactMap(\.delimiter).first { !$0.isEmpty }
        guard let leaf = MailboxTree.validatedLeaf(input, delimiter: delimiter) else {
            alert = .invalidFolderName
            return
        }
        await enqueue(.createMailbox(name: leaf), accountId: accountId, failure: .invalidFolderName)
    }

    func removeAccount(_ account: AccountRecord) async {
        guard let services else { return }
        let outcome = await services.run(account, .deleteAccount(accountId: account.id))
        if case .failure(let error) = outcome {
            alert = SidebarAlert(title: String(localized: "Could not delete account"), error: error)
        }
    }

    func delegate(accountId: Int64, userId: String) async -> Bool {
        await runAccountCommand(
            accountId: accountId, .delegate(accountId: accountId, userId: userId),
            failure: String(localized: "Could not delegate access"))
    }

    func revokeDelegation(accountId: Int64, userId: String) async -> Bool {
        await runAccountCommand(
            accountId: accountId, .revokeDelegation(accountId: accountId, userId: userId),
            failure: String(localized: "Could not revoke delegation"))
    }

    private func runAccountCommand(accountId: Int64, _ command: SettingsCommand, failure: String) async -> Bool {
        guard let services, let account = accounts.first(where: { $0.id == accountId }) else { return false }
        let outcome = await services.run(account, command)
        if case .failure(let error) = outcome {
            alert = SidebarAlert(title: failure, error: error)
            return false
        }
        return true
    }

    // MARK: - Folder menu (§3.3)

    func markFolderRead(_ row: MailboxTreeRow, accountId: Int64) async {
        await enqueue(.markMailboxRead(mailboxId: row.id), accountId: accountId, failure: nil)
    }

    func createSubfolder(named input: String, parent: MailboxTreeRow, accountId: Int64, node: MailboxNode?) async {
        guard let leaf = MailboxTree.validatedLeaf(input, delimiter: parent.delimiter) else {
            alert = .invalidFolderName
            return
        }
        let created = await enqueue(
            .createMailbox(name: MailboxTree.childName(of: parent, leaf: leaf)), accountId: accountId,
            failure: .invalidFolderName)
        if created, let node { setExpanded(true, accountId: accountId, node: node) }
    }

    func renameFolder(_ row: MailboxTreeRow, to input: String, accountId: Int64) async {
        guard let leaf = MailboxTree.validatedLeaf(input, delimiter: row.delimiter) else {
            alert = .invalidFolderName
            return
        }
        let name = MailboxTree.renamedName(of: row, to: leaf)
        guard name != row.name else { return }
        await enqueue(.renameMailbox(mailboxId: row.id, name: name), accountId: accountId, failure: .renameFailed)
    }

    /// `parent` nil is the top level ("/").
    func moveFolder(_ row: MailboxTreeRow, under parent: MailboxTreeRow?, accountId: Int64) async {
        await enqueue(
            .moveMailbox(mailboxId: row.id, parentMailboxId: parent?.id), accountId: accountId,
            failure: SidebarAlert(title: String(localized: "An error occurred, unable to move the mailbox.")))
    }

    func setSubscribed(_ value: Bool, row: MailboxTreeRow, accountId: Int64) async {
        await enqueue(.setMailboxSubscribed(mailboxId: row.id, subscribed: value), accountId: accountId, failure: nil)
    }

    func setSyncInBackground(_ value: Bool, row: MailboxTreeRow, accountId: Int64) async {
        await enqueue(
            .setMailboxSyncInBackground(mailboxId: row.id, enabled: value), accountId: accountId, failure: nil)
    }

    func clearFolder(_ row: MailboxTreeRow, accountId: Int64) async {
        await enqueue(.clearMailbox(mailboxId: row.id), accountId: accountId, failure: nil)
    }

    func deleteFolder(_ row: MailboxTreeRow, accountId: Int64) async {
        await enqueue(.deleteMailbox(mailboxId: row.id), accountId: accountId, failure: nil)
    }

    func isRepairBlocked(_ mailboxId: Int64) -> Bool {
        guard let until = repairBlockedUntil[mailboxId] else { return false }
        return until > now()
    }

    /// Repair is a command, not a queue kind: it acts on server state there is no local form
    /// of. A 429 is the server's rate limit; the folder's Repair stays disabled until the
    /// `Retry-After` it named (10 minutes, the server's own window, when it named none).
    func repairFolder(_ row: MailboxTreeRow, accountId: Int64) async {
        guard let services, let account = accounts.first(where: { $0.id == accountId }) else { return }
        switch await services.run(account, .repairMailbox(mailboxId: row.id)) {
        case .success:
            refresh?(accountId, row.id)
        case .failure(.rateLimited(let retryAfter)):
            let wait = retryAfter.map { Double($0.components.seconds) } ?? Self.defaultRepairWait
            repairBlockedUntil[row.id] = now().addingTimeInterval(wait)
            let minutes = max(1, Int((wait / 60).rounded(.up)))
            alert = SidebarAlert(title: String(localized: "Please wait \(minutes) minutes before repairing again"))
        case .failure(let error):
            alert = SidebarAlert(title: String(localized: "Could not repair folder"), error: error)
        }
    }

    static let defaultRepairWait: TimeInterval = 600

    // MARK: - Drag and drop (§3.4)

    /// Whether `payload` may land on `node` of `accountId`: a selectable real folder, same
    /// account, not where the messages already are, not Drafts or Sent, and right `i`.
    func canDrop(_ payload: MessageDragPayload, on node: MailboxNode, accountId: Int64) -> Bool {
        guard let row = node.row, row.isSelectable, payload.accountId == accountId,
            row.id != payload.sourceMailboxId, row.allows("i")
        else { return false }
        if let role = row.specialRole?.lowercased(), role == "drafts" || role == "sent" { return false }
        if let account = accounts.first(where: { $0.id == accountId }), let remoteId = row.remoteId,
            remoteId == account.draftsMailboxId || remoteId == account.sentMailboxId
        {
            return false
        }
        return true
    }

    /// Moves every payload that may land here; refuses the drop when none may.
    func drop(_ payloads: [MessageDragPayload], on node: MailboxNode, accountId: Int64) async -> Bool {
        defer { endDrag() }
        let valid = payloads.filter { canDrop($0, on: node, accountId: accountId) }
        guard let services, let destination = node.row?.id, !valid.isEmpty else { return false }
        for payload in valid {
            await services.move(payload, destination)
        }
        return true
    }

    // MARK: - Queue

    /// Applies one operation locally and queues it. An enqueue failure is local -- the
    /// mailbox vanished from the mirror, the account is gone -- so it is shown at once; a
    /// server refusal later surfaces as the footer's "actions waiting".
    @discardableResult
    private func enqueue(_ operation: MailOperation, accountId: Int64, failure: SidebarAlert?) async -> Bool {
        guard let queue = services?.queue(accountId) else { return false }
        do {
            try await queue.perform(operation, accountId: accountId)
            return true
        } catch {
            Self.logger.error("enqueue failed: \(String(describing: error), privacy: .public)")
            alert = failure ?? SidebarAlert(title: String(localized: "The change could not be saved."))
            return false
        }
    }
}

/// A text prompt the sidebar shows as an alert with one field.
enum SidebarPrompt: Identifiable {
    case addFolder(accountId: Int64)
    case addSubfolder(parent: MailboxTreeRow, node: MailboxNode, accountId: Int64)
    case rename(row: MailboxTreeRow, accountId: Int64)

    var id: String {
        switch self {
        case .addFolder(let accountId): "add:\(accountId)"
        case .addSubfolder(let parent, _, _): "sub:\(parent.id)"
        case .rename(let row, _): "rename:\(row.id)"
        }
    }

    var title: String {
        switch self {
        case .addFolder: String(localized: "Add folder")
        case .addSubfolder: String(localized: "Add subfolder")
        case .rename: String(localized: "Rename")
        }
    }

    /// What the field starts with: the folder's own name for a rename, empty otherwise.
    var initialText: String {
        if case .rename(let row, _) = self { return row.pathComponents.last ?? row.name }
        return ""
    }
}

/// A destructive action waiting for the user's yes.
enum SidebarConfirmation: Identifiable {
    case removeAccount(AccountRecord)
    case clearFolder(row: MailboxTreeRow, accountId: Int64)
    case deleteFolder(row: MailboxTreeRow, accountId: Int64)

    var id: String {
        switch self {
        case .removeAccount(let account): "remove:\(account.id)"
        case .clearFolder(let row, _): "clear:\(row.id)"
        case .deleteFolder(let row, _): "delete:\(row.id)"
        }
    }
}

/// An error alert: a title in the user's words, and the server's own message when it sent
/// one -- never an error description, which is for the log.
struct SidebarAlert: Identifiable, Equatable {
    let title: String
    var message: String?
    var id: String { title + (message ?? "") }

    init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    init(title: String, error: MailError) {
        self.title = title
        if case .server(_, let message) = error { self.message = message }
    }

    static var invalidFolderName: SidebarAlert {
        SidebarAlert(
            title: String(
                localized:
                    "Unable to create mailbox. The name likely contains invalid characters. Please try another name."
            )
        )
    }

    static var renameFailed: SidebarAlert {
        SidebarAlert(title: String(localized: "An error occurred, unable to rename the mailbox."))
    }
}
