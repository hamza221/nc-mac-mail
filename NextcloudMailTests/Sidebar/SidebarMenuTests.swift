// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The v2 sidebar against a real, migrated, in-memory mirror and a real `MutationQueue` with
/// no drainer -- exactly the offline case: every menu item must leave a queue row and its
/// local change, and nothing else. Commands are scripted, so the 429 path runs without a
/// server.
@MainActor
@Suite("SidebarMenus")
struct SidebarMenuTests {
    private let identity = ServerIdentity(serverURL: "https://cloud.example.com", loginName: "lorelai")

    private final class CommandLog {
        var commands: [String] = []
    }

    private func makeModel(
        _ store: MailStore,
        outcome: CommandOutcome = .success,
        log: CommandLog = CommandLog(),
        moves: @escaping @MainActor (MessageDragPayload, Int64) -> Void = { _, _ in },
        now: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 1_000_000) }
    ) -> SidebarStore {
        let model = SidebarStore(store: store, now: now)
        model.attach(
            SidebarServices(
                queue: { _ in MutationQueue(store: store) },
                run: { _, command in
                    log.commands.append(String(describing: command))
                    return outcome
                },
                requestQuota: { _ in },
                move: { payload, destination in moves(payload, destination) }
            ))
        model.start()
        return model
    }

    @discardableResult
    private func makeAccount(
        _ store: MailStore, remoteId: Int64 = 1, loginName: String = "lorelai", sortOrder: Int = 0,
        provisioningId: Int64? = nil, draftsMailboxId: Int64? = nil
    ) async throws -> AccountRecord {
        let write = AccountWrite(
            identity: ServerIdentity(serverURL: identity.serverURL, loginName: loginName),
            remoteId: remoteId,
            name: "Work",
            emailAddress: "\(loginName)@example.com",
            sortOrder: sortOrder,
            draftsMailboxId: draftsMailboxId,
            provisioningId: provisioningId
        )
        return try #require(try await store.upsert(accounts: [write]).first)
    }

    @discardableResult
    private func makeMailbox(
        _ store: MailStore, accountId: Int64, remoteId: Int64, name: String, specialRole: String? = nil,
        rawJSON: String = "{}"
    ) async throws -> MailboxRecord {
        let write = MailboxWrite(
            accountId: accountId, remoteId: remoteId, name: name, delimiter: "/", displayName: name,
            specialRole: specialRole, rawJSON: rawJSON)
        return try #require(try await store.upsert(mailboxes: [write], accountId: accountId).first)
    }

    private func settled(_ condition: () -> Bool, attempts: Int = 2000) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func pendingKinds(_ store: MailStore, accountId: Int64) async throws -> [String] {
        try await store.pendingOperations(accountId: accountId).map(\.kind)
    }

    // MARK: - Layout from the store

    @Test("one account: Priority inbox only; a second account adds All inboxes")
    func virtualEntriesFollowAccounts() async throws {
        let store = try MailStore.inMemory()
        let first = try await makeAccount(store)
        try await makeMailbox(store, accountId: first.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        let model = makeModel(store)
        #expect(await settled { model.layout.accounts.count == 1 })
        #expect(model.layout.virtualEntries == [.priorityInbox])

        try await makeAccount(store, loginName: "second", sortOrder: 1)
        #expect(await settled { model.layout.virtualEntries.count == 2 })
    }

    @Test("the Outbox entry appears with the first outbox message and goes with the last")
    func outboxVisibility() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let model = makeModel(store)
        #expect(await settled { model.accounts.count == 1 })
        #expect(model.layout.outboxCount == nil)

        try await store.replaceOutbox(
            [OutboxMessageRecord(accountId: account.id, remoteId: 9, syncedAt: 1)], accountId: account.id)
        #expect(await settled { model.layout.outboxCount == 1 })
        try await store.replaceOutbox([], accountId: account.id)
        #expect(await settled { model.layout.outboxCount == nil })
    }

    @Test("Favorites sits under the Inbox in the account's items")
    func favoritesUnderInbox() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let inbox = try await makeMailbox(
            store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        let model = makeModel(store)
        #expect(await settled { model.layout.accounts.first?.items.count == 2 })
        #expect(model.layout.accounts.first?.items.last == .favorites(inboxId: inbox.id))
    }

    @Test("a provisioned account whose connection test failed is disabled; another shows the error row")
    func connectionTestDecidesDisabled() async throws {
        let store = try MailStore.inMemory()
        let login = try await store.ensureLogin(identity)
        let provisioned = try await makeAccount(store, provisioningId: 3)
        try await makeMailbox(store, accountId: provisioned.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        let model = makeModel(store)
        #expect(await settled { model.layout.accounts.first?.items.isEmpty == false })

        let failed = #"{"status":"ready","data":{"ok":false}}"#
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: try #require(login.id), kind: SettingsCommands.connectionTestKind,
                key: String(provisioned.id), payloadJSON: failed, fetchedAt: 1))
        #expect(await settled { model.layout.accounts.first?.items.isEmpty == true })
        #expect(model.isDisabled(provisioned))
        #expect(!model.hasConnectionError(provisioned))
    }

    // MARK: - Folder menu → queue

    @Test("Add folder while offline queues createMailbox and shows the folder at once")
    func addFolderQueues() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        let model = makeModel(store)
        #expect(await settled { model.mailboxRows[account.id]?.count == 1 })

        await model.createFolder(named: " Projects ", accountId: account.id)
        #expect(try await pendingKinds(store, accountId: account.id) == ["createMailbox"])
        #expect(await settled { model.mailboxRows[account.id]?.contains { $0.name == "Projects" } == true })
        #expect(model.alert == nil)
    }

    @Test("a folder name with the delimiter is refused, and nothing is queued")
    func invalidNameRefused() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        let model = makeModel(store)
        #expect(await settled { model.mailboxRows[account.id]?.count == 1 })

        await model.createFolder(named: "A/B", accountId: account.id)
        #expect(model.alert == .invalidFolderName)
        #expect(try await pendingKinds(store, accountId: account.id).isEmpty)
    }

    @Test("Add subfolder joins the parent's path; Rename keeps the parent")
    func subfolderAndRename() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let work = try await makeMailbox(store, accountId: account.id, remoteId: 2, name: "Work")
        let model = makeModel(store)
        #expect(await settled { model.mailboxRows[account.id]?.count == 1 })
        let row = try #require(model.mailboxRows[account.id]?.first)

        await model.createSubfolder(named: "Acme", parent: row, accountId: account.id, node: nil)
        #expect(await settled { model.mailboxRows[account.id]?.contains { $0.name == "Work/Acme" } == true })

        await model.renameFolder(row, to: "Clients", accountId: account.id)
        #expect(try await pendingKinds(store, accountId: account.id) == ["createMailbox", "renameMailbox"])
        #expect(await settled { model.mailboxRows[account.id]?.first { $0.id == work.id }?.name == "Clients" })
    }

    @Test("every other folder item queues its own kind")
    func folderItemsQueueTheirKinds() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        try await makeMailbox(store, accountId: account.id, remoteId: 2, name: "Work")
        try await makeMailbox(store, accountId: account.id, remoteId: 3, name: "Old")
        let model = makeModel(store)
        #expect(await settled { model.mailboxRows[account.id]?.count == 3 })
        let rows = try #require(model.mailboxRows[account.id])
        let inbox = try #require(rows.first { $0.name == "INBOX" })
        let work = try #require(rows.first { $0.name == "Work" })
        let old = try #require(rows.first { $0.name == "Old" })

        await model.markFolderRead(inbox, accountId: account.id)
        await model.setSubscribed(false, row: work, accountId: account.id)
        await model.setSyncInBackground(true, row: work, accountId: account.id)
        await model.moveFolder(old, under: work, accountId: account.id)
        await model.clearFolder(work, accountId: account.id)
        await model.deleteFolder(old, accountId: account.id)
        #expect(
            try await pendingKinds(store, accountId: account.id) == [
                "markMailboxRead", "setMailboxSubscribed", "setMailboxSyncInBackground", "moveMailbox",
                "clearMailbox", "deleteMailbox",
            ])
    }

    // MARK: - Account menu → queue / commands

    @Test("Move down queues the new order for both accounts and reorders locally")
    func moveAccountQueuesOrder() async throws {
        let store = try MailStore.inMemory()
        let first = try await makeAccount(store, sortOrder: 0)
        let second = try await makeAccount(store, loginName: "second", sortOrder: 1)
        let model = makeModel(store)
        #expect(await settled { model.accounts.count == 2 })

        await model.moveAccount(first, up: false)
        #expect(try await pendingKinds(store, accountId: first.id) == ["patchAccount"])
        #expect(try await pendingKinds(store, accountId: second.id) == ["patchAccount"])
        #expect(await settled { model.accounts.map(\.id) == [second.id, first.id] })
    }

    @Test("Show only subscribed folders is a queued account patch")
    func showSubscribedOnlyQueues() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let model = makeModel(store)
        #expect(await settled { model.accounts.count == 1 })
        await model.setShowSubscribedOnly(true, account: account)
        #expect(try await pendingKinds(store, accountId: account.id) == ["patchAccount"])
        #expect(await settled { model.accounts.first?.showSubscribedOnly == true })
    }

    @Test("Remove account runs deleteAccount; a failure says so")
    func removeAccountRunsCommand() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let log = CommandLog()
        let model = makeModel(store, outcome: .failure(.server(status: 500, message: nil)), log: log)
        #expect(await settled { model.accounts.count == 1 })
        await model.removeAccount(account)
        #expect(log.commands.contains { $0.hasPrefix("deleteAccount") })
        #expect(model.alert?.title == "Could not delete account")
    }

    @Test("Repair: a 429 says how long to wait and disables Repair until then")
    func repairRateLimited() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 2, name: "Work")
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let model = makeModel(
            store, outcome: .failure(.rateLimited(retryAfter: .seconds(300))), now: { clock })
        #expect(await settled { model.mailboxRows[account.id]?.count == 1 })
        let row = try #require(model.mailboxRows[account.id]?.first)

        await model.repairFolder(row, accountId: account.id)
        #expect(model.alert?.title == "Please wait 5 minutes before repairing again")
        #expect(model.isRepairBlocked(row.id))
        clock = clock.addingTimeInterval(301)
        #expect(!model.isRepairBlocked(row.id))
    }

    @Test("Repair: a 429 without Retry-After falls back to the server's 10 minutes")
    func repairRateLimitedDefault() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 2, name: "Work")
        let model = makeModel(store, outcome: .failure(.rateLimited(retryAfter: nil)))
        #expect(await settled { model.mailboxRows[account.id]?.count == 1 })
        let row = try #require(model.mailboxRows[account.id]?.first)
        await model.repairFolder(row, accountId: account.id)
        #expect(model.alert?.title == "Please wait 10 minutes before repairing again")
    }

    // MARK: - Drops

    @Test("drop targets: same account, not the source, not Drafts, right i")
    func dropTargets() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store, draftsMailboxId: 5)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        try await makeMailbox(store, accountId: account.id, remoteId: 5, name: "Entwürfe")
        try await makeMailbox(store, accountId: account.id, remoteId: 6, name: "ReadOnly", rawJSON: #"{"myAcls":"lr"}"#)
        try await makeMailbox(store, accountId: account.id, remoteId: 7, name: "Work")
        var moved: [Int64] = []
        let model = makeModel(store, moves: { _, destination in moved.append(destination) })
        #expect(await settled { model.mailboxNodes[account.id]?.count == 4 })
        let nodes = try #require(model.mailboxNodes[account.id])
        func node(_ name: String) throws -> MailboxNode { try #require(nodes.first { $0.displayName == name }) }
        let inboxId = try #require(try node("INBOX").row?.id)
        let payload = MessageDragPayload(messageIds: [1], sourceMailboxId: inboxId, accountId: account.id)

        #expect(!model.canDrop(payload, on: try node("INBOX"), accountId: account.id))
        #expect(!model.canDrop(payload, on: try node("Entwürfe"), accountId: account.id))
        #expect(!model.canDrop(payload, on: try node("ReadOnly"), accountId: account.id))
        #expect(!model.canDrop(payload, on: try node("Work"), accountId: account.id + 1))
        #expect(model.canDrop(payload, on: try node("Work"), accountId: account.id))

        #expect(await model.drop([payload], on: try node("Work"), accountId: account.id))
        #expect(moved == [try #require(try node("Work").row?.id)])
    }
}
