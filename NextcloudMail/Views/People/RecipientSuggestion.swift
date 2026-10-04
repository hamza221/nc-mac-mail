// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// One address a chip stands for.
nonisolated struct RecipientAddress: Hashable, Sendable {
    var email: String
    var label: String?
}

/// One row of the recipient autocomplete (ADR-0072).
nonisolated struct RecipientSuggestion: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A person card of the contacts mirror.
        case contact(contactId: Int64)
        /// A contact group card; picking it adds every mirrored member.
        case group(contactId: Int64, members: [RecipientAddress])
        /// An address only ever seen in mirrored mail, with how many messages carried it.
        case mail(count: Int)
        /// A row of the server's `/api/autoComplete` answer the local sources did not have.
        /// `source` is the server's (`contacts`, `groups`, `collector`); a Nextcloud group's
        /// address is `nextcloud:<gid>`, which the server expands on send.
        case server(source: String?)
        /// One of the user's own addresses: an account or an alias.
        case identity(accountId: Int64)
    }

    var id: String
    var email: String?
    var label: String?
    var kind: Kind

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return email ?? ""
    }

    /// What picking this suggestion inserts: the address, or a group's members.
    var expandedAddresses: [RecipientAddress] {
        if case .group(_, let members) = kind { return members }
        guard let email else { return [] }
        return [RecipientAddress(email: email, label: label)]
    }
}

/// One of the user's own addresses, as the ranking sees it.
nonisolated struct OwnIdentity: Hashable, Sendable {
    var accountId: Int64
    var email: String
    var name: String?
}

/// The merge of the four local sources and the cached server rows into one list, ranked per
/// ADR-0072: contacts (and contact groups) by most recent interaction, then mail-derived
/// addresses by frequency, then the server's extra rows, own identities last. Pure, so the
/// rule is tested without a store.
nonisolated enum RecipientRanking {
    /// What the caller gathered for one term.
    struct Input: Sendable {
        var contacts: [ContactSuggestionRow] = []
        /// Members of the groups among `contacts`, by group contact id.
        var groupMembers: [Int64: [RecipientAddress]] = [:]
        /// Mail-derived addresses that matched the term.
        var mailMatches: [MailAddressStatistic] = []
        /// Every mail-derived address by lowercased email, for the contacts' recency.
        var lastSeen: [String: Int64] = [:]
        /// Own identities that matched the term, account address first.
        var identityMatches: [OwnIdentity] = []
        /// Every own address, lowercased, matched or not: an own address is never shown as
        /// a contact or a mail-derived row.
        var ownEmails: Set<String> = []
        /// The server supplement for this term, in the server's order.
        var server: [RecipientSuggestionRecord] = []
    }

    static func rank(_ input: Input, limit: Int) -> [RecipientSuggestion] {
        var seen = input.ownEmails
        var result: [RecipientSuggestion] = []

        result += rankedContacts(input, seen: &seen)

        let mail = input.mailMatches.sorted {
            ($0.count, $0.lastSeenAt, $1.email.lowercased()) > ($1.count, $1.lastSeenAt, $0.email.lowercased())
        }
        for stat in mail where seen.insert(stat.email.lowercased()).inserted {
            result.append(
                RecipientSuggestion(
                    id: stat.email.lowercased(), email: stat.email, label: nonEmpty(stat.label),
                    kind: .mail(count: stat.count)))
        }

        for row in input.server {
            if let email = nonEmpty(row.email) {
                guard seen.insert(email.lowercased()).inserted else { continue }
                result.append(
                    RecipientSuggestion(
                        id: email.lowercased(), email: email, label: nonEmpty(row.label),
                        kind: .server(source: row.source)))
            } else if let label = nonEmpty(row.label), seen.insert("server:" + label).inserted {
                result.append(
                    RecipientSuggestion(
                        id: "server:" + label, email: nil, label: label, kind: .server(source: row.source)))
            }
        }

        var identities = Set<String>()
        for identity in input.identityMatches where identities.insert(identity.email.lowercased()).inserted {
            result.append(
                RecipientSuggestion(
                    id: identity.email.lowercased(), email: identity.email, label: nonEmpty(identity.name),
                    kind: .identity(accountId: identity.accountId)))
        }
        return Array(result.prefix(limit))
    }

    private struct RankedContact {
        var suggestion: RecipientSuggestion
        var lastSeen: Int64?
        var sortName: String
        var position: Int
    }

    private static func rankedContacts(_ input: Input, seen: inout Set<String>) -> [RecipientSuggestion] {
        var candidates: [RankedContact] = []
        var groups = Set<Int64>()
        for row in input.contacts {
            let name = contactName(row)
            if row.isGroup {
                guard groups.insert(row.contactId).inserted else { continue }
                let members = input.groupMembers[row.contactId] ?? []
                guard !members.isEmpty else { continue }
                let lastSeen = members.compactMap { input.lastSeen[$0.email.lowercased()] }.max()
                candidates.append(
                    RankedContact(
                        suggestion: RecipientSuggestion(
                            id: "group:\(row.contactId)", email: nil, label: name,
                            kind: .group(contactId: row.contactId, members: members)),
                        lastSeen: lastSeen, sortName: (name ?? "").lowercased(), position: 0))
                continue
            }
            guard let email = nonEmpty(row.email) else { continue }
            candidates.append(
                RankedContact(
                    suggestion: RecipientSuggestion(
                        id: email.lowercased(), email: email, label: name, kind: .contact(contactId: row.contactId)),
                    lastSeen: input.lastSeen[email.lowercased()],
                    sortName: (name ?? email).lowercased(),
                    position: row.emailPosition ?? 0))
        }
        candidates.sort { lhs, rhs in
            switch (lhs.lastSeen, rhs.lastSeen) {
            case (let left?, let right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if lhs.sortName != rhs.sortName { return lhs.sortName < rhs.sortName }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.suggestion.id < rhs.suggestion.id
        }
        var result: [RecipientSuggestion] = []
        for candidate in candidates {
            if candidate.suggestion.email != nil {
                guard seen.insert(candidate.suggestion.id).inserted else { continue }
            }
            result.append(candidate.suggestion)
        }
        return result
    }

    /// The name a contact goes by: the card's `FN`, else given and family names, else the
    /// nickname or organisation.
    static func contactName(_ row: ContactSuggestionRow) -> String? {
        if let name = nonEmpty(row.displayName) { return name }
        let parts = [row.givenName, row.familyName].compactMap(nonEmpty)
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return nonEmpty(row.nickname) ?? nonEmpty(row.organization)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The local matching rule for the in-memory sources (mail-derived addresses, identities),
/// kept the same as the contacts index's: every typed word prefixes a word of the name or the
/// address, or the whole term appears inside the address.
nonisolated struct RecipientTerm: Sendable, Equatable {
    let raw: String
    let tokens: [String]

    init(_ text: String) {
        raw = Self.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        tokens = Self.words(raw)
    }

    var isEmpty: Bool { tokens.isEmpty }

    func matches(emailLowercased email: String, words: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        if email.contains(raw) { return true }
        return tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
    }

    /// Letter-or-digit runs, lowercased — the `unicode61` tokeniser's view, so `o'brien`
    /// and `alice@example.com` split the same way here as in the contacts index.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in fold(text).unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Lowercased without diacritics, as the contacts index's `remove_diacritics 2` sees text.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}
