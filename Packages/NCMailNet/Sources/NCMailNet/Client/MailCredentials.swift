// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// What `MailClient` needs in order to sign a request.
///
/// A protocol rather than a concrete type because WS-01 owns the Keychain-backed
/// credential and this workstream must not define it. Anything that can produce
/// a login name and an app password conforms, including a future token holder
/// that refreshes.
public protocol MailCredentials: Sendable {
    var loginName: String { get }
    var appPassword: String { get }
}

/// A credential held in memory, for tests and for the moment between Login Flow
/// v2 answering and the Keychain write.
public struct BasicCredentials: MailCredentials, Sendable {
    public let loginName: String
    public let appPassword: String

    public init(loginName: String, appPassword: String) {
        self.loginName = loginName
        self.appPassword = appPassword
    }
}

extension MailCredentials {
    /// The value of the `Authorization` header.
    ///
    /// Never log the result, and never put it in an error. `Data.base64` is not
    /// encryption; it is the password in a thin disguise.
    var basicAuthorizationHeader: String {
        let pair = "\(loginName):\(appPassword)"
        let encoded = Data(pair.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
