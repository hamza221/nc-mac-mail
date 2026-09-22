// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet

/// One signed-in account, live: the identity the Keychain holds and the client that talks to
/// its server.
///
/// `NCMailSync/Mirror/**` (WS-04) and `NCMailSync/Sync/**` (WS-05) attach a
/// `MirrorCoordinator` and a `SyncScheduler` to an account once they exist —
/// `AppSession.accountsFromKeychain()` is where each one is built today, and where each one
/// would gain a coordinator and a scheduler alongside its client.
struct AccountSession: Identifiable, Equatable {
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
        id = "\(server.absoluteString)#\(loginName)"
    }

    static func == (lhs: AccountSession, rhs: AccountSession) -> Bool {
        lhs.id == rhs.id
    }
}
