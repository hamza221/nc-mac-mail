// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet

/// The account form's values and every rule the web client's `AccountForm.vue` applies to
/// them, as a value type so the rules are testable without a view or a server.
///
/// Nothing here talks to anything: ``AccountSetupModel`` owns the flow and mutates this.
struct AccountSetupForm: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case auto
        case manual

        var id: String { rawValue }
    }

    /// The server's `*SslMode` values. `tls` is STARTTLS, as in the web client.
    enum Security: String, CaseIterable, Identifiable {
        case none
        case ssl
        case tls

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: String(localized: "None")
            case .ssl: String(localized: "SSL/TLS")
            case .tls: String(localized: "STARTTLS")
            }
        }

        /// The port the web client switches to when the security changes.
        var imapPort: Int { self == .ssl ? 993 : 143 }
        var smtpPort: Int { self == .ssl ? 465 : 587 }
    }

    enum Provider: Equatable {
        case google
        case microsoft
    }

    var mode: Mode = .auto
    var accountName = ""
    var emailAddress = ""
    /// Auto mode's password.
    var password = ""
    var classificationEnabled = true

    var imapHost = ""
    var imapPort = 993
    var imapSecurity: Security = .ssl
    var imapUser = ""
    var imapPassword = ""
    var smtpHost = ""
    var smtpPort = 587
    var smtpSecurity: Security = .tls
    var smtpUser = ""
    var smtpPassword = ""
    /// SMTP host, user and password follow IMAP's until any SMTP field is edited by hand.
    private(set) var mirrorsSMTP = true

    /// The login's provider sign-in URLs (`google-oauth-url`, `microsoft-oauth-url`); nil when
    /// the admin has not configured that provider.
    var googleOAuthURL: String?
    var microsoftOAuthURL: String?

    // MARK: - Mode

    /// Entering Manual fills empty users with the address and empty passwords with Auto's.
    mutating func setMode(_ newMode: Mode) {
        mode = newMode
        guard newMode == .manual else { return }
        if imapUser.isEmpty { imapUser = emailAddress }
        if imapPassword.isEmpty { imapPassword = password }
        if smtpUser.isEmpty { smtpUser = emailAddress }
        if smtpPassword.isEmpty { smtpPassword = password }
    }

    // MARK: - IMAP edits, mirrored into SMTP while the coupling holds

    mutating func setIMAPHost(_ value: String) {
        imapHost = value
        if mirrorsSMTP { smtpHost = value }
    }

    mutating func setIMAPUser(_ value: String) {
        imapUser = value
        if mirrorsSMTP { smtpUser = value }
    }

    mutating func setIMAPPassword(_ value: String) {
        imapPassword = value
        if mirrorsSMTP { smtpPassword = value }
    }

    mutating func setIMAPSecurity(_ value: Security) {
        imapSecurity = value
        imapPort = value.imapPort
    }

    // MARK: - SMTP edits, each of which severs the coupling

    mutating func setSMTPHost(_ value: String) {
        smtpHost = value
        mirrorsSMTP = false
    }

    mutating func setSMTPUser(_ value: String) {
        smtpUser = value
        mirrorsSMTP = false
    }

    mutating func setSMTPPassword(_ value: String) {
        smtpPassword = value
        mirrorsSMTP = false
    }

    mutating func setSMTPPort(_ value: Int) {
        smtpPort = value
        mirrorsSMTP = false
    }

    mutating func setSMTPSecurity(_ value: Security) {
        smtpSecurity = value
        smtpPort = value.smtpPort
        mirrorsSMTP = false
    }

    // MARK: - Discovery

    /// Writes a discovered configuration into the Manual fields, as `applyAutoConfig` does,
    /// so a later failure leaves the user something to correct.
    mutating func apply(_ discovered: DiscoveredConfiguration) {
        if let imap = discovered.imap {
            imapUser = imap.username ?? emailAddress
            imapHost = imap.host
            imapPort = imap.port
            imapSecurity = imap.security
            imapPassword = password
        }
        if let smtp = discovered.smtp {
            smtpUser = smtp.username ?? emailAddress
            smtpHost = smtp.host
            smtpPort = smtp.port
            smtpSecurity = smtp.security
            smtpPassword = password
        }
    }

    // MARK: - Validation

    /// The web client's `isValidEmail` regular expression, verbatim.
    static func isValidEmail(_ value: String) -> Bool {
        guard let emailPattern else { return false }
        return value.wholeMatch(of: emailPattern) != nil
    }

    /// A constant pattern: nil only if it stopped compiling, which the tests would catch.
    nonisolated(unsafe) private static let emailPattern = try? Regex(
        #"(([^<>()\[\]\\.,;:\s@"]+(\.[^<>()\[\]\\.,;:\s@"]+)*)|(".+"))@(localhost|((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,})))"#
    )

    /// Shown live under the address once something has been typed.
    var showsEmailFormatHint: Bool { !emailAddress.isEmpty && !Self.isValidEmail(emailAddress) }

    /// The domain the first ISPDB lookup asks about.
    var emailDomain: String { emailAddress.split(separator: "@").last.map(String.init) ?? "" }

    var provider: Provider? {
        if imapHost == "imap.gmail.com" || smtpHost == "smtp.gmail.com" { return .google }
        if imapHost == "outlook.office365.com" || smtpHost == "outlook.office365.com" { return .microsoft }
        return nil
    }

    /// The provider's sign-in URL template, when the detected provider is configured.
    var oauthURLTemplate: String? {
        switch provider {
        case .google: googleOAuthURL
        case .microsoft: microsoftOAuthURL
        case nil: nil
        }
    }

    var usesOAuth: Bool { oauthURLTemplate != nil }

    /// The web client's `isDisabledAuto`: a password is optional only when both providers
    /// are configured, whatever the address.
    var canSubmitAuto: Bool {
        Self.isValidEmail(emailAddress)
            && !(googleOAuthURL == nil && password.isEmpty)
            && !(microsoftOAuthURL == nil && password.isEmpty)
    }

    var canSubmitManual: Bool {
        Self.isValidEmail(emailAddress)
            && !imapHost.isEmpty && imapPort > 0 && !imapUser.isEmpty && (usesOAuth || !imapPassword.isEmpty)
            && !smtpHost.isEmpty && smtpPort > 0 && !smtpUser.isEmpty && (usesOAuth || !smtpPassword.isEmpty)
    }

    var canSubmit: Bool { mode == .auto ? canSubmitAuto : canSubmitManual }

    /// The submit check after discovery: OAuth needs no password, anything else does.
    var isMissingPassword: Bool {
        guard !usesOAuth else { return false }
        return mode == .auto ? password.isEmpty : imapPassword.isEmpty || smtpPassword.isEmpty
    }

    /// The idle label of the submit button.
    var submitLabel: String {
        if mode == .manual, usesOAuth {
            return provider == .google
                ? String(localized: "Sign in with Google") : String(localized: "Sign in with Microsoft")
        }
        return String(localized: "Connect")
    }

    /// The request `createAccount` sends: hosts trimmed, passwords omitted for OAuth.
    var request: AccountRequest {
        AccountRequest(
            accountName: accountName,
            emailAddress: emailAddress,
            imapHost: imapHost.trimmingCharacters(in: .whitespaces),
            imapPort: imapPort,
            imapSslMode: imapSecurity.rawValue,
            imapUser: imapUser,
            smtpHost: smtpHost.trimmingCharacters(in: .whitespaces),
            smtpPort: smtpPort,
            smtpSslMode: smtpSecurity.rawValue,
            smtpUser: smtpUser,
            imapPassword: usesOAuth ? nil : imapPassword,
            smtpPassword: usesOAuth ? nil : smtpPassword,
            authMethod: usesOAuth ? "xoauth2" : "password",
            classificationEnabled: classificationEnabled
        )
    }

    /// The provider URL with the minted state and the address filled in, as the web client
    /// does (`_state_`, `_email_` URI-encoded).
    func oauthURL(state: String, email: String) -> URL? {
        guard let template = oauthURLTemplate else { return nil }
        let encoded = email.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))
        return URL(
            string:
                template
                .replacingOccurrences(of: "_state_", with: state)
                .replacingOccurrences(of: "_email_", with: encoded ?? email))
    }
}

/// One discovered server, from ISPDB or the MX port probe.
struct DiscoveredServer: Equatable {
    var username: String?
    var host: String
    var port: Int
    var security: AccountSetupForm.Security
}

struct DiscoveredConfiguration: Equatable {
    var imap: DiscoveredServer?
    var smtp: DiscoveredServer?

    var isEmpty: Bool { imap == nil && smtp == nil }
}
