// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet

/// One signed-in account, live: the identity the Keychain holds and the client that talks to
/// its server.
///
/// `AccountEngine` is what attaches a `MirrorCoordinator`, an `OperationDrainer` and a
/// `SyncScheduler` to one of these. It does so per *account row* rather than per Keychain
/// entry, because a coordinator takes a local account id and only a row has one (ADR-0033),
/// and it finds its way back here through ``identifier(server:loginName:)``.
/// `nonisolated` because the app target defaults to `@MainActor` and this value is built on
/// the detached task that reads the Keychain (ADR-0054).
nonisolated struct AccountSession: Identifiable, Equatable, Sendable {
    /// Stable across relaunches. The server's numeric account id is a fact the sync engine
    /// discovers, not one the Keychain knows, so identity here is the pair that does identify
    /// a Keychain item.
    let id: String
    let server: URL
    let loginName: String
    let client: MailClient

    init(server: URL, loginName: String, client: MailClient) {
        self.server = server
        self.loginName = loginName
        self.client = client
        id = AccountSession.identifier(server: server.absoluteString, loginName: loginName)
    }

    /// The same pair an `account` row carries in `serverURL` and `loginName` (ADR-0033),
    /// spelled once so that matching a row to the credentials that can talk to it is not two
    /// string formats that have to agree.
    static func identifier(server: String, loginName: String) -> String {
        "\(server)#\(loginName)"
    }

    static func == (lhs: AccountSession, rhs: AccountSession) -> Bool {
        lhs.id == rhs.id
    }
}
