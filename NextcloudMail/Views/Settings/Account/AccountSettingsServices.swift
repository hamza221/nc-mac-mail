// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync

/// The engines account settings write through, as closures.
///
/// Nothing here returns data: the queue takes an operation and writes the store, a command
/// answers with an outcome only (ADR-0068), and a sharee search lands in a `serverResult`
/// row the model observes. Closures so `AccountSettingsModelTests` can hand in a real
/// `MutationQueue` over an in-memory store and scripted outcomes.
struct AccountSettingsServices {
    var queue: @MainActor (_ accountId: Int64) -> MutationQueue?
    var run: @MainActor (_ account: AccountRecord, _ command: SettingsCommand) async -> CommandOutcome
    /// Asks the login's fetcher for user sharees matching a term; returns at once.
    var searchSharees: @MainActor (_ account: AccountRecord, _ term: String) -> Void
}

/// A command for an account whose login has no running engine: signed out, or not started.
nonisolated enum AccountSettingsServiceError: Error {
    case loginNotRunning
}

extension AccountSettingsServices {
    static func live(_ session: AppSession) -> AccountSettingsServices {
        AccountSettingsServices(
            queue: { [weak session] accountId in
                session?.engine.mutationQueue(accountId: accountId)
            },
            run: { [weak session] account, command in
                let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
                guard let commands = session?.engine.settingsCommands(sessionId: sessionId) else {
                    return .failure(.transport(AccountSettingsServiceError.loginNotRunning))
                }
                return await commands.run(command)
            },
            searchSharees: { [weak session] account, term in
                let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
                guard let fetcher = session?.engine.serverResults(sessionId: sessionId) else { return }
                Task { await fetcher.request(kind: .sharees, key: term) }
            }
        )
    }
}
