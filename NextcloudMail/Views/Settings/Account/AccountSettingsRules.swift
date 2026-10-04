// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync

/// The connection security choices both server forms offer, spelled as the server stores them.
enum ConnectionSecurity: String, CaseIterable, Sendable {
    case none
    case ssl
    case tls

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .ssl: String(localized: "SSL/TLS")
        case .tls: String(localized: "STARTTLS")
        }
    }
}

/// The Mail server form (§8): prefilled from the account, saved through `updateMailServer`.
struct MailServerDraft: Equatable, Sendable {
    var imapHost: String
    var imapPort: Int
    var imapSecurity: ConnectionSecurity
    var imapUser: String
    var imapPassword = ""
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: ConnectionSecurity
    var smtpUser: String
    var smtpPassword = ""
    let accountName: String
    let emailAddress: String
    let authMethod: String?

    init(account: AccountRecord) {
        let facts = AccountFacts(account)
        accountName = account.name
        emailAddress = account.emailAddress
        authMethod = facts.authMethod
        imapHost = facts.imapHost
        imapPort = facts.imapPort
        imapSecurity = ConnectionSecurity(rawValue: facts.imapSslMode) ?? .ssl
        imapUser = facts.imapUser
        smtpHost = facts.smtpHost
        smtpPort = facts.smtpPort
        smtpSecurity = ConnectionSecurity(rawValue: facts.smtpSslMode) ?? .tls
        smtpUser = facts.smtpUser
    }

    var isValid: Bool {
        ![imapHost, imapUser, smtpHost, smtpUser].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && (1...65_535).contains(imapPort) && (1...65_535).contains(smtpPort)
    }

    /// An OAuth account (Google, Microsoft) signs in with a token; it has no password to change.
    var usesOAuth: Bool { authMethod == "xoauth2" }

    /// A blank password is sent as nil: the server then keeps the one it has.
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
            imapPassword: imapPassword.isEmpty ? nil : imapPassword,
            smtpPassword: smtpPassword.isEmpty ? nil : smtpPassword,
            authMethod: authMethod
        )
    }
}

/// The Sieve server form (§8.5): host defaults to the IMAP host, STARTTLS on 4190, and the
/// IMAP credentials unless "Custom" is chosen.
struct SieveServerDraft: Equatable, Sendable {
    var enabled: Bool
    var host: String
    var port: Int
    var security: ConnectionSecurity
    var customCredentials: Bool
    var user: String
    var password = ""

    init(account: AccountRecord, sieve: SieveStateRecord?) {
        let facts = AccountFacts(account)
        let fields = AccountFacts.fields(account.rawJSON)
        enabled = account.sieveEnabled
        host = sieve?.sieveHost ?? fields["sieveHost"]?.stringValue ?? ""
        if host.isEmpty { host = facts.imapHost }
        port = sieve?.sievePort ?? 4190
        security =
            ConnectionSecurity(rawValue: sieve?.sieveSslMode ?? fields["sieveSslMode"]?.stringValue ?? "") ?? .tls
        user = sieve?.sieveUser ?? fields["sieveUser"]?.stringValue ?? ""
        customCredentials = !user.isEmpty && user != facts.imapUser
    }

    var isValid: Bool {
        guard enabled else { return true }
        return !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(port)
            && (!customCredentials || !user.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Empty user and password tell the server to reuse the IMAP credentials.
    var request: SieveAccountRequest {
        guard enabled else {
            return SieveAccountRequest(
                sieveEnabled: false, sieveHost: "", sievePort: 4190, sieveUser: "", sievePassword: "",
                sieveSslMode: "none")
        }
        return SieveAccountRequest(
            sieveEnabled: true,
            sieveHost: host.trimmingCharacters(in: .whitespaces),
            sievePort: port,
            sieveUser: customCredentials ? user : "",
            sievePassword: customCredentials ? password : "",
            sieveSslMode: security.rawValue
        )
    }
}

/// The text a failed command shows under its button, the web's "Oh Snap!" line with the
/// server's own message.
enum CommandMessage {
    /// The Sieve parser's message arrives JSON-encoded inside the error body
    /// (`"\"Expected token …\""`, fixture `error-sieve-script-422.json`); shown unquoted.
    static func serverText(_ outcome: CommandOutcome) -> String? {
        guard var text = outcome.serverMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("\""), text.hasSuffix("\""),
            let decoded = try? JSONDecoder().decode(String.self, from: Data(text.utf8))
        {
            text = decoded
        }
        return text
    }

    static func failure(_ outcome: CommandOutcome) -> String? {
        guard case .failure(let error) = outcome else { return nil }
        let detail = serverText(outcome) ?? error.description
        return String(format: String(localized: "Oh Snap! %@"), detail)
    }

    /// §8.5: a 422 from the Sieve script save is the parser's verdict.
    static func sieveScriptFailure(_ outcome: CommandOutcome) -> String? {
        guard case .failure(let error) = outcome else { return nil }
        if case .server(422, _) = error {
            return String(
                format: String(localized: "Oh Snap! The syntax seems to be incorrect: %@"),
                serverText(outcome) ?? "")
        }
        return failure(outcome)
    }
}

/// §8.2's certificate list for one identity.
enum CertificateRules {
    /// Has a private key, carries the identity's address, is still valid tomorrow, and can
    /// both sign and encrypt.
    static func eligible(
        _ certificates: [SmimeCertificateRecord], email: String, now: Date
    ) -> [SmimeCertificateRecord] {
        let tomorrow = Int64(now.timeIntervalSince1970) + 86_400
        return certificates.filter { certificate in
            certificate.hasPrivateKey
                && certificate.emailAddress.caseInsensitiveCompare(email) == .orderedSame
                && (certificate.notAfter ?? 0) > tomorrow
                && certificate.canSign && certificate.canEncrypt
        }
    }

    static func info(_ certificate: SmimeCertificateRecord) -> [String: AnyJSON] {
        AccountFacts.fields(certificate.infoJSON)
    }

    /// "{commonName} - Valid until {date}".
    static func label(_ certificate: SmimeCertificateRecord) -> String {
        let name = info(certificate)["commonName"]?.stringValue ?? certificate.emailAddress
        let date = Date(timeIntervalSince1970: TimeInterval(certificate.notAfter ?? 0))
        return String(
            format: String(localized: "%@ - Valid until %@"), name,
            date.formatted(date: .abbreviated, time: .omitted))
    }

    static func isChainVerified(_ certificate: SmimeCertificateRecord) -> Bool {
        if case .bool(let verified)? = info(certificate)["isChainVerified"] { return verified }
        return true
    }
}

/// §8.3's two signature warnings.
enum SignatureRules {
    static let largeSignatureBytes = 2 * 1024 * 1024

    static func isLarge(_ signature: String) -> Bool {
        signature.utf8.count > largeSignatureBytes
    }

    /// Images in the signature force rich text on a plain-text account.
    static func overridesPlainText(_ signature: String, editorMode: String?) -> Bool {
        editorMode == AccountEditorMode.plain && SignatureText.hasImage(signature)
    }
}

/// `editorMode` as the server spells it.
enum AccountEditorMode {
    static let plain = "plaintext"
    static let rich = "richtext"
}

/// §8.3: "0 or empty disables". The patch sends 0 for that — nil would mean "leave alone" —
/// and the server stores it as null.
enum TrashRetention {
    /// The days to patch, or nil for text that is not a number ≥ 0.
    static func days(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let days = Int(trimmed), days >= 0 else { return nil }
        return days
    }

    /// The field's text for a stored value: empty when disabled.
    static func text(_ days: Int?) -> String {
        guard let days, days > 0 else { return "" }
        return String(days)
    }
}
