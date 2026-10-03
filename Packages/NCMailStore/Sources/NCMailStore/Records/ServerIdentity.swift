// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Which signed-in Nextcloud login a mirrored account came from.
///
/// The server's numeric account id is unique on one instance and says nothing across two, so
/// it cannot be the mirror's identity on its own
/// ([ADR-0033](../../../../docs/decisions/0033-accounts-have-a-local-identity.md)). This pair
/// is what scopes it, and it is deliberately the same pair the Keychain item is keyed by
/// (`Keychain.allAccounts()` returns exactly these), so the app can go from an account row
/// back to the credentials that can talk to it without inventing a second identity scheme.
///
/// `serverURL` is a string rather than a `URL` because it is a database column and because
/// two `URL`s that differ only in a trailing slash would be two rows. `NCMailNet.ServerURL`
/// normalises before the Keychain sees it; this type stores whatever it was given.
public struct ServerIdentity: Codable, Sendable, Hashable {
    public var serverURL: String
    public var loginName: String

    public init(serverURL: String, loginName: String) {
        self.serverURL = serverURL
        self.loginName = loginName
    }

    public init(serverURL: URL, loginName: String) {
        self.init(serverURL: serverURL.absoluteString, loginName: loginName)
    }
}
