// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// One signed-in account: the server it belongs to, the login name Login Flow
/// v2 returned, and the app password that authenticates every request after.
///
/// `appPassword` is the asset [security.md](../../../../docs/architecture/security.md)
/// calls out by name. It never appears in `description`, in a log, or in a
/// crash report — a credential in any of those is a security incident, not a
/// bug.
public struct Credentials: Sendable, Equatable, CustomStringConvertible {
    public let server: URL
    public let loginName: String
    public let appPassword: String

    public init(server: URL, loginName: String, appPassword: String) {
        self.server = server
        self.loginName = loginName
        self.appPassword = appPassword
    }

    /// Deliberately omits `appPassword`. A grep for the password across logs
    /// and crash metadata must find nothing, and `description` is where a
    /// `String(describing:)` or an interpolated log line would otherwise leak it.
    public var description: String {
        "Credentials(server: \(server), loginName: \(loginName))"
    }
}

/// Lets a `Credentials` loaded from the Keychain go straight into
/// `MailClient(credentials:)` with no adapter. WS-02 defined `MailCredentials`
/// as a protocol specifically so that this package's two halves would not
/// need to depend on each other's concrete types while both were being built
/// at once — this conformance is the seam meeting in the middle.
extension Credentials: MailCredentials {}
