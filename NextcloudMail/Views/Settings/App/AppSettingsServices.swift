// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync

/// The engines app settings write through, as closures, per Nextcloud login.
///
/// The same shape as ``AccountSettingsServices``: the queue takes an operation and writes the
/// store, a command answers with an outcome only (ADR-0068), and a sharee search lands in a
/// `serverResult` row the model observes. Closures so `AppSettingsModelTests` can hand in a
/// real `MutationQueue` over an in-memory store and scripted outcomes.
struct AppSettingsServices {
    var queue: @MainActor (_ accountId: Int64) -> MutationQueue?
    var run: @MainActor (_ login: LoginRecord, _ command: SettingsCommand) async -> CommandOutcome
    /// Asks the login's fetcher for users and groups matching a term; returns at once.
    var searchSharees: @MainActor (_ login: LoginRecord, _ term: String) -> Void
}

extension AppSettingsServices {
    static func live(_ session: AppSession) -> AppSettingsServices {
        AppSettingsServices(
            queue: { [weak session] accountId in
                session?.engine.mutationQueue(accountId: accountId)
            },
            run: { [weak session] login, command in
                let sessionId = AccountSession.identifier(server: login.serverURL, loginName: login.loginName)
                guard let commands = session?.engine.settingsCommands(sessionId: sessionId) else {
                    return .failure(.transport(AccountSettingsServiceError.loginNotRunning))
                }
                return await commands.run(command)
            },
            searchSharees: { [weak session] login, term in
                let sessionId = AccountSession.identifier(server: login.serverURL, loginName: login.loginName)
                guard let fetcher = session?.engine.serverResults(sessionId: sessionId) else { return }
                Task { await fetcher.request(kind: .sharees, key: term) }
            }
        )
    }
}
