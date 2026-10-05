// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore

/// One signed-in Nextcloud login, live: the identity the Keychain holds and the two clients
/// that talk to its server — `MailClient` for the Mail app's routes, `DAVClient` for CardDAV
/// and CalDAV (contacts and the calendar list).
///
/// `AccountEngine` runs the login's own machinery (contacts, calendars, server state) once
/// per session, and a `MirrorCoordinator`, an `OperationDrainer`, a `SyncScheduler` and an
/// `OutboxSender` per *account row* of it, because those take a local account id and only a
/// row has one (ADR-0033); a row finds its way back here through
/// ``identifier(server:loginName:)``.
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
    let dav: DAVClient

    /// Both clients signed with the same credentials, which is every real session.
    init(server: URL, credentials: any MailCredentials) {
        self.init(
            server: server,
            loginName: credentials.loginName,
            client: MailClient(server: server, credentials: credentials),
            dav: DAVClient(server: server, credentials: credentials)
        )
    }

    init(server: URL, loginName: String, client: MailClient, dav: DAVClient) {
        self.server = server
        self.loginName = loginName
        self.client = client
        self.dav = dav
        id = AccountSession.identifier(server: server.absoluteString, loginName: loginName)
    }

    /// The `login` row's key in the mirror.
    var identity: ServerIdentity {
        ServerIdentity(serverURL: server, loginName: loginName)
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
