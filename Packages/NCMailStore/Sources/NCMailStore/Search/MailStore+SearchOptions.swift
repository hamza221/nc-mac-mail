// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
public import GRDB

/// One tag the "Search parameters" sheet offers, merged across accounts by IMAP label —
/// which is also how ``SearchQuery/Parameters/tags`` matches.
public struct SearchTagOption: FetchableRecord, Decodable, Sendable, Equatable, Hashable, Identifiable {
    public var imapLabel: String
    public var displayName: String
    public var color: String?

    public var id: String { imapLabel }

    public init(imapLabel: String, displayName: String, color: String? = nil) {
        self.imapLabel = imapLabel
        self.displayName = displayName
        self.color = color
    }
}

/// An address already seen in mirrored mail, offered while typing into an address field.
public struct SearchAddressSuggestion: FetchableRecord, Decodable, Sendable, Equatable, Hashable, Identifiable {
    public var email: String
    public var label: String?

    public var id: String { email.lowercased() }
}

extension MailStore {
    /// The tags a search in `scope` can filter by, live, sorted by name.
    ///
    /// A mailbox scope offers its account's tags; `.all` offers every account's, one row per
    /// label. Where two accounts name the same label differently the alphabetically first
    /// name wins, so the list is the same on every read.
    public func observeSearchTags(scope: SearchQuery.Scope) -> StoreObservation<[SearchTagOption]> {
        observation { db in
            let filter: String
            switch scope {
            case .mailbox: filter = "WHERE accountId = (SELECT accountId FROM mailbox WHERE id = :scopeId)"
            case .account: filter = "WHERE accountId = :scopeId"
            case .all: filter = ""
            }
            return try SearchTagOption.fetchAll(
                db,
                sql: """
                    SELECT imapLabel, min(displayName) AS displayName, min(color) AS color
                    FROM tag \(filter)
                    GROUP BY imapLabel
                    ORDER BY displayName COLLATE NOCASE, imapLabel
                    """,
                arguments: ["scopeId": SearchStatement.scopeId(scope)]
            )
        }
    }

    /// Addresses from mirrored envelopes that start with `prefix`, most frequent first.
    ///
    /// A prefix of the address, not of the name: `LIKE 'pre%'` against the `COLLATE NOCASE`
    /// index is a range scan, where a name search would read every address in the mirror.
    /// `%` and `_` in the input are escaped, so they match themselves. Fewer than two
    /// characters suggest nothing, the same rule as search terms.
    public func searchAddressSuggestions(prefix: String, limit: Int = 8) async throws -> [SearchAddressSuggestion] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= FTS5MatchExpression.minimumTermLength, limit > 0 else { return [] }
        let pattern =
            trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        return try await read { db in
            try SearchAddressSuggestion.fetchAll(
                db,
                sql: """
                    SELECT min(email) AS email, max(label) AS label
                    FROM messageAddress
                    WHERE email LIKE :pattern ESCAPE '\\'
                    GROUP BY email COLLATE NOCASE
                    ORDER BY count(*) DESC, email COLLATE NOCASE
                    LIMIT :limit
                    """,
                arguments: ["pattern": pattern, "limit": limit]
            )
        }
    }
}
