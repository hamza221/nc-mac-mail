// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync

/// One running piece of sync machinery, as ``AccountEngine`` drives it: started once,
/// told about the network, woken when the Mac wakes, stopped at sign-out.
///
/// The `engine…` names are deliberate. The actors already have `start()`, `stop()` and
/// `apply(conditions:)` with their own meanings — or lack one, which is what the
/// conformances below paper over — and a requirement named `stop()` would quietly bind to a
/// library method added later with different semantics.
nonisolated protocol EnginePart: Sendable {
    func engineStart() async
    func engineStop() async
    func engineApply(_ conditions: MirrorConditions) async
    func engineWake() async
}

/// Conditions that stop everything an actor would send. Used as `stop()` by the actors that
/// have none: `MirrorCoordinator`, `ServerStateMirror` and `ServerResultFetcher` stop their
/// work when told they are offline, and a stopped instance is never told otherwise again.
nonisolated private let stopped = MirrorConditions(isOffline: true)

extension MirrorCoordinator: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await apply(conditions: stopped) }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}

extension SyncScheduler: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await stop() }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}

extension AvatarFetcher: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await stop() }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}

extension OutboxSender: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await stop() }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}

extension ContactsSync: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await stop() }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async { await wake() }
}

extension CalendarListSync: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await stop() }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async { await wake() }
}

/// On demand only: nothing to start, and offline is how it stops taking requests.
extension ServerResultFetcher: EnginePart {
    nonisolated func engineStart() async {}
    nonisolated func engineStop() async { await apply(conditions: stopped) }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}

/// Starting it is the `.launch` refresh, on its own task so a stop is not held up behind a
/// pass of 25 requests; the deep-reconcile trigger is `SyncScheduler`'s. Offline cancels the
/// outbox poll and turns every later trigger into a no-op, which is the only stop it has.
extension ServerStateMirror: EnginePart {
    nonisolated func engineStart() async {
        Task { await self.refresh(trigger: .launch) }
    }
    nonisolated func engineStop() async { await apply(conditions: stopped) }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}

/// Everything running for one Nextcloud login — one ``AccountSession`` — however many mail
/// accounts hang off it.
nonisolated struct LoginEngines: Sendable {
    /// In start order. Stopped in reverse.
    var parts: [any EnginePart]
    /// Carries the login's `ContactWriteHandler`, so every queue and drainer of its accounts
    /// can apply and send the contact and calendar kinds.
    var queueConfiguration = MutationQueueConfiguration()
    /// The scheduler's deep-reconcile trigger and the outbox engine's `refreshOutbox` hook.
    var serverState: ServerStateMirror?
    var results: ServerResultFetcher?
    var files: FilesListingSync?
}

/// Everything running for one mail account row.
nonisolated struct AccountEngines: Sendable {
    /// In start order. Stopped in reverse.
    var parts: [any EnginePart]
    var prioritiser: (any BodyPrioritising)?
    var progress: AsyncStream<MirrorProgress>?
    var pendingSummary: AsyncStream<PendingSummary>?
    var drainer: OperationDrainer?
    var outbox: OutboxSender?
    var setSelectedMailbox: @Sendable (Int64?) async -> Void = { _ in }
    var syncNow: @Sendable (Int64?) async -> Void = { _ in }
    var retryFailed: @Sendable () async -> Void = {}
    var wakeDrainer: @Sendable () async -> Void = {}
}

/// How ``AccountEngine`` builds what it runs. ``live`` is the app; a test passes parts that
/// record their calls and a discovery that opens no socket.
struct EngineFactory {
    /// Asks a server which mail accounts a login has, which writes the rows the engine
    /// starts accounts from (ADR-0047).
    var discover: @Sendable (MailStore, AccountSession) async throws -> Void
    var login:
        @MainActor (
            _ store: MailStore,
            _ session: AccountSession,
            _ loginId: Int64,
            _ followedUp: @escaping @Sendable ([Int64]) async -> Void
        ) -> LoginEngines
    var account:
        @MainActor (_ store: MailStore, _ row: AccountRecord, _ session: AccountSession, _ login: LoginEngines) ->
            AccountEngines

    static let live = EngineFactory(
        discover: { store, session in
            let rows = try await MirrorCoordinator.discoverAccounts(
                store: store,
                client: session.client,
                identity: session.identity
            )
            AccountEngine.logger.info("discovered \(rows.count, privacy: .public) account(s) for one identity")
        },
        login: { store, session, loginId, followedUp in
            let pendingWrites = MutationQueue(store: store)
            let contacts = ContactsSync(
                store: store,
                client: session.dav,
                loginId: loginId,
                pendingWrites: { try await pendingWrites.pendingDAVWrites(loginId: loginId) }
            )
            let calendars = CalendarListSync(store: store, client: session.dav, loginId: loginId)
            // A write that reached the server is read back by the sync that owns its rows,
            // so the server's spelling of the result lands (WS-24).
            let handler = ContactWriteHandler(
                store: store,
                client: session.dav,
                afterSend: { write in
                    if write.kind == .calendarPut { await calendars.wake() } else { await contacts.wake() }
                }
            )
            let results = ServerResultFetcher(store: store, client: session.client, identity: session.identity)
            let files = FilesListingSync(store: store, dav: session.dav, client: session.client, loginId: loginId)
            let serverState = ServerStateMirror(
                store: store,
                client: session.client,
                identity: session.identity,
                onFollowedUp: followedUp
            )
            let notices = ServerNotificationPoller(store: store, client: session.client, identity: session.identity)
            return LoginEngines(
                parts: [calendars, contacts, results, files, serverState, notices],
                queueConfiguration: MutationQueueConfiguration(dav: handler),
                serverState: serverState,
                results: results,
                files: files
            )
        },
        account: { store, row, session, login in
            let mirror = MirrorCoordinator(store: store, client: session.client, accountId: row.id)
            let drainer = OperationDrainer(
                store: store,
                client: session.client,
                accountId: row.id,
                configuration: login.queueConfiguration
            )
            let scheduler = SyncScheduler(
                store: store,
                client: session.client,
                accountId: row.id,
                drainer: drainer,
                mirror: mirror,
                serverState: login.serverState
            )
            let avatars = AvatarFetcher(store: store, client: session.client, accountId: row.id)
            let serverState = login.serverState
            let outbox = OutboxSender(
                store: store,
                client: session.client,
                accountId: row.id,
                configuration: OutboxConfiguration(
                    syncMailbox: { mailboxId in await scheduler.syncNow(mailboxId: mailboxId) },
                    refreshOutbox: { await serverState?.refreshOutbox() }
                )
            )
            return AccountEngines(
                parts: [mirror, scheduler, avatars, outbox],
                prioritiser: mirror,
                progress: mirror.progress,
                pendingSummary: drainer.pendingCount,
                drainer: drainer,
                outbox: outbox,
                setSelectedMailbox: { await scheduler.setSelectedMailbox($0) },
                syncNow: { await scheduler.syncNow(mailboxId: $0) },
                retryFailed: { await drainer.retryAll() },
                wakeDrainer: { await drainer.wake() }
            )
        }
    )
}
