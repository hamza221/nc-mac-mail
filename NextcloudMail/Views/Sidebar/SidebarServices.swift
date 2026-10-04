// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync

/// The engines the sidebar's menus write through, as closures.
///
/// Nothing here returns data: a queue takes an operation and writes the store; a command
/// answers with an outcome only ([ADR-0068](../../../docs/decisions/0068-settings-commands.md));
/// a quota request lands in a `serverResult` row the sidebar observes. Closures rather than
/// `AppSession` itself so `SidebarStoreTests` can hand in a real `MutationQueue` over an
/// in-memory store and a scripted command outcome -- the 429 case included -- without a
/// running engine.
struct SidebarServices {
    /// The account's mutation queue: every §3.3 folder change and the account patches. Nil
    /// once the session is gone.
    var queue: @MainActor (_ accountId: Int64) -> MutationQueue?
    /// One online-only command against the account's login.
    var run: @MainActor (_ account: AccountRecord, _ command: SettingsCommand) async -> CommandOutcome
    /// Asks the login's fetcher for the account's quota row; returns at once.
    var requestQuota: @MainActor (_ account: AccountRecord) -> Void
    /// A message drop on a folder, through the triage move (thread or message per the list
    /// view, with undo).
    var move: @MainActor (_ payload: MessageDragPayload, _ destinationMailboxId: Int64) async -> Void
}

/// A command for an account whose login has no running engine -- signed out in another
/// window, or not started yet.
nonisolated enum SidebarServiceError: Error {
    case loginNotRunning
}

extension SidebarServices {
    static func live(_ session: AppSession) -> SidebarServices {
        SidebarServices(
            queue: { [weak session] accountId in
                session?.engine.mutationQueue(accountId: accountId)
            },
            run: { [weak session] account, command in
                let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
                guard let commands = session?.engine.settingsCommands(sessionId: sessionId) else {
                    return .failure(.transport(SidebarServiceError.loginNotRunning))
                }
                return await commands.run(command)
            },
            requestQuota: { [weak session] account in
                let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
                guard let fetcher = session?.engine.serverResults(sessionId: sessionId) else { return }
                Task { await fetcher.request(kind: .quota, key: ServerResultKind.accountKey(account.id)) }
            },
            move: { [weak session] payload, destinationMailboxId in
                guard let session else { return }
                let selection = Selection(
                    messageIds: payload.messageIds,
                    scope: Selection.scope(for: session.navigation.listView)
                )
                await session.triage.actions.move(selection, to: destinationMailboxId)
            }
        )
    }
}
