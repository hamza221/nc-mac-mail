// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/autoconfig/ispdb/{host}/{email}`, inside the `JSONEnvelope`.
///
/// Verified live (Mail 5.12) against the Mozilla ISPDB for gmail.com:
/// `{"status":"success","data":{"imapConfig":{…},"smtpConfig":{…}}}`.
/// Either half can be missing when the database only knows one protocol, and
/// `data` is null when the host is unknown, so callers take `JSONEnvelope<AutoconfigResult?>`.
public struct AutoconfigResult: Decodable, Sendable, Hashable {
    public let imapConfig: AutoconfigServer?
    public let smtpConfig: AutoconfigServer?

    private enum CodingKeys: String, CodingKey {
        case imapConfig
        case smtpConfig
    }
}

/// One suggested server, IMAP or SMTP.
///
/// Verified: `{"username":"user@gmail.com","host":"imap.gmail.com","port":993,"security":"ssl"}`.
public struct AutoconfigServer: Decodable, Sendable, Hashable {
    public let username: String?
    public let host: String
    public let port: Int
    /// `ssl`, `tls` or `none`, matching the account form's SSL-mode values.
    public let security: String?

    private enum CodingKeys: String, CodingKey {
        case username
        case host
        case port
        case security
    }
}
