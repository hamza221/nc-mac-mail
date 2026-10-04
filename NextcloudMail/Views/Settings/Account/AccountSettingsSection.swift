// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore

/// One entry of the account settings' section list, in the web client's order (§8).
enum AccountSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case aliases
    case certificates
    case writingMode
    case signature
    case defaultFolders
    case trashRetention
    case folderSearch
    case autoresponder
    case classification
    case quickActions
    case calendar
    case filters
    case mailServer
    case sieveServer
    case sieveScript
    case delegation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aliases: String(localized: "Aliases")
        case .certificates: String(localized: "Alias to S/MIME certificate mapping")
        case .writingMode: String(localized: "Writing mode")
        case .signature: String(localized: "Signature")
        case .defaultFolders: String(localized: "Default folders")
        case .trashRetention: String(localized: "Automatic trash deletion")
        case .folderSearch: String(localized: "Folder search")
        case .autoresponder: String(localized: "Autoresponder")
        case .classification: String(localized: "Classification")
        case .quickActions: String(localized: "Quick actions")
        case .calendar: String(localized: "Calendar settings")
        case .filters: String(localized: "Filters")
        case .mailServer: String(localized: "Mail server")
        case .sieveServer: String(localized: "Sieve server")
        case .sieveScript: String(localized: "Sieve script editor")
        case .delegation: String(localized: "Delegation")
        }
    }

    /// The §8 visibility row, decided from the account row alone.
    ///
    /// Autoresponder and Filters are always listed: without Sieve they show the hint card
    /// that points at Sieve server, as the web does. The calendar switch exists on servers
    /// whose account payload carries `imipCreate` (Mail on Nextcloud 33 and later) — the
    /// payload is the evidence, not a version number.
    static func visible(for account: AccountRecord) -> [AccountSettingsSection] {
        let facts = AccountFacts(account)
        return allCases.filter { section in
            switch section {
            case .calendar: facts.offersImipCreate
            case .mailServer: !account.isDelegated
            case .sieveScript: account.sieveEnabled
            case .delegation: !account.isDelegated && account.provisioningId == nil
            default: true
            }
        }
    }

    /// Provisioned accounts take their servers from the administrator's provisioning
    /// configuration (§9), so these sections show the explanation instead of a form.
    func isLocked(for account: AccountRecord) -> Bool {
        switch self {
        case .mailServer, .sieveServer: account.provisioningId != nil
        default: false
        }
    }
}

/// The fields of the server's account payload the mirror keeps only in `rawJSON`: the
/// IMAP/SMTP connection, and whether the server knows the calendar setting.
struct AccountFacts: Equatable, Sendable {
    var imapHost = ""
    var imapPort = 993
    var imapSslMode = "ssl"
    var imapUser = ""
    var smtpHost = ""
    var smtpPort = 587
    var smtpSslMode = "tls"
    var smtpUser = ""
    var authMethod: String?
    var offersImipCreate = false

    init(_ account: AccountRecord) {
        let fields = Self.fields(account.rawJSON)
        imapHost = fields["imapHost"]?.stringValue ?? ""
        imapPort = fields["imapPort"].flatMap(Self.int) ?? imapPort
        imapSslMode = fields["imapSslMode"]?.stringValue ?? imapSslMode
        imapUser = fields["imapUser"]?.stringValue ?? ""
        smtpHost = fields["smtpHost"]?.stringValue ?? ""
        smtpPort = fields["smtpPort"].flatMap(Self.int) ?? smtpPort
        smtpSslMode = fields["smtpSslMode"]?.stringValue ?? smtpSslMode
        smtpUser = fields["smtpUser"]?.stringValue ?? ""
        authMethod = fields["authMethod"]?.stringValue
        offersImipCreate = fields["imipCreate"] != nil
    }

    static func fields(_ rawJSON: String) -> [String: AnyJSON] {
        (try? JSONDecoder().decode(AnyJSON.self, from: Data(rawJSON.utf8)))?.objectValue ?? [:]
    }

    private static func int(_ value: AnyJSON) -> Int? {
        switch value {
        case .int(let number): number
        case .string(let text): Int(text)
        default: nil
        }
    }
}
