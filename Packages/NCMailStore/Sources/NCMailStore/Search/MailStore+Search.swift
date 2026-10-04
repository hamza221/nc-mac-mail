// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// How many hits a live search keeps on screen before the window is extended.
    ///
    /// Search is ranked, not chronological, so the far end of the list holds the least
    /// relevant answers. A window rather than everything, for the same reason the message
    /// list windows: `ORDER BY bm25(...)` scores every match, and returning them all would
    /// put tens of thousands of rows through the decoder to draw thirty.
    public static let defaultSearchWindow = 0..<200

    // MARK: - Searching

    /// Hits for `query`: ranked best first when it carries text, newest first when it is
    /// filters alone.
    ///
    /// A query with no criteria returns no results rather than every message — empty or
    /// whitespace-only text, text the tokeniser would keep nothing of (a lone `-`, a bracket,
    /// an emoji), and terms shorter than two characters, with no filter switched on.
    /// ``SearchQuery/hasCriteria`` answers false for all of them and this returns early.
    ///
    /// Nothing here touches the network, and it could not: `NCMailStore` cannot see
    /// `NCMailNet`. Search is a read of the mirror, which is what
    /// [ADR-0011](../../../../docs/decisions/0011-fts5-standalone-index.md) and the mirror
    /// itself exist for.
    public func search(_ query: SearchQuery, limit: Int, offset: Int = 0) async throws -> [SearchResult] {
        try await dbQueue.read { db in
            guard let statement = SearchStatement(query: query, range: offset..<(offset + limit)) else { return [] }
            return try SearchResult.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
        }
    }

    /// The same hits, live, shaped as list rows: a value now and another whenever a matching
    /// row changes.
    ///
    /// The message list windows over a `(Range<Int>) -> StoreObservation<[MessageRow]>`, and
    /// this is what gets installed there, so search results replace the list rather than
    /// becoming a second one. A message deleted locally leaves the results on the next value,
    /// because the trigger that removes its index row
    /// ([ADR-0024](../../../../docs/decisions/0024-fts-deletes-in-a-trigger.md)) is a write
    /// GRDB's observation sees. `messageAddress` is `WITHOUT ROWID`, so its own writes are
    /// not observed — but an envelope's addresses are only ever rewritten together with its
    /// `message` row, which is.
    public func observeSearchRows(_ query: SearchQuery, range: Range<Int>) -> StoreObservation<[MessageRow]> {
        observation { db in
            guard let statement = SearchStatement(query: query, range: range) else { return [] }
            return try MessageRow.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
        }
    }

    // MARK: - Coverage

    /// How much of the scope has its body in the index, live, so the footer counts up during
    /// the backfill and takes itself off screen when the mirror completes.
    public func observeSearchCoverage(scope: SearchQuery.Scope) -> StoreObservation<SearchCoverage> {
        observation { db in try Self.fetchCoverage(db, scope: scope) }
    }

    private static func fetchCoverage(_ db: Database, scope: SearchQuery.Scope) throws -> SearchCoverage {
        let sql = """
            SELECT
                coalesce(sum(CASE WHEN candidate.bodyState = 'present' THEN 1 ELSE 0 END), 0)
                    AS indexedMessages,
                coalesce(sum(CASE WHEN candidate.bodyState = 'failed' THEN 1 ELSE 0 END), 0)
                    AS failedMessages,
                count(*) AS totalMessages,
                (SELECT count(*) FROM mailbox WHERE isMirrored = 0\(SearchStatement.mailboxScopeSQL(scope)))
                    AS unmirroredMailboxes
            FROM message candidate
            WHERE 1 = 1\(SearchStatement.scopeSQL(scope))
            """
        let coverage = try SearchCoverage.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments(["scopeId": SearchStatement.scopeId(scope)])
        )
        // An aggregate with no GROUP BY always yields exactly one row, so the fallback is
        // unreachable. It is here so this function contains no force unwrap.
        return coverage ?? SearchCoverage(indexedMessages: 0, failedMessages: 0, totalMessages: 0)
    }
}

/// One search, as SQL and the values bound into it.
///
/// Built per query rather than kept as one fixed string, because the sheet's fields each add
/// a clause and the list fields add one bound value per entry. Everything the user typed is
/// a bound value or has been through ``FTS5MatchExpression``; the only text spliced into the
/// SQL is the clauses below and generated parameter names.
///
/// **Two shapes.** With text (field, Subject or Body) the FTS5 table drives and the result is
/// ranked by `bm25`. Without text the `message` table drives, newest first, through
/// `idxMessageMailboxSent` in a mailbox scope and `idxMessageAccount` in an account scope —
/// so a filter-only search walks the index in display order and stops at the window's end
/// rather than sorting the mailbox. Both shapes share every filter clause, written against
/// the alias `candidate`.
///
/// **Determinism.** Each shape ends its ordering on the message id, so two messages with the
/// same score and the same timestamp always come back in the same order and a window never
/// shows one twice or skips one.
struct SearchStatement {
    let sql: String
    let arguments: StatementArguments

    /// Nil when there is nothing to run: an empty window, or a query without criteria.
    init?(query: SearchQuery, range: Range<Int>) {
        guard !range.isEmpty, query.hasCriteria else { return nil }
        var values: [String: (any DatabaseValueConvertible)?] = [
            "limit": range.count,
            "offset": range.lowerBound,
            "scopeId": Self.scopeId(query.scope),
        ]
        let filters =
            Self.scopeSQL(query.scope)
            + Self.flagSQL(query.flags)
            + Self.parameterSQL(query.parameters, values: &values)

        if let match = query.matchExpression {
            values["match"] = match
            sql = Self.rankedSQL(filters: filters)
        } else {
            sql = Self.chronologicalSQL(filters: filters)
        }
        arguments = StatementArguments(values)
    }

    /// The ranked shape.
    ///
    /// `bm25` weights `subject` and `people` far above `body`, which ADR-0011 asked for: a
    /// message *about* the roadmap should beat one that mentions it in a quoted reply forty
    /// lines down, and one *from* Sookie should beat one where somebody said her name.
    /// `preview` sits between them because it is the opening of the body, and an opening line
    /// is more often what a message is about than line four hundred is.
    ///
    /// bm25 returns a negative score, smaller being a better match, so a plain ascending
    /// `ORDER BY` is best first. `sentAt DESC` breaks ties, because two equally relevant
    /// messages are best offered newest first; the id breaks the rest.
    ///
    /// **The window is taken before the row is built, and that is the performance of this
    /// workstream.** Ranking has to score every match — there is no index over relevance —
    /// so an unselective query at fifty thousand messages scores fifty thousand documents
    /// whatever the shape of the statement. What the subquery removes is everything else done
    /// fifty thousand times: the fourteen-column projection and the mailbox lookup now run
    /// for the fifty rows that survive. See `SearchPerformanceTests`.
    ///
    /// The thread columns are the flat list's: a result is one message, not a conversation.
    /// Grouping ranked hits by thread would make the count mean "messages in this thread"
    /// rather than "hits in this thread", which is the one reading a searcher would not
    /// expect.
    private static func rankedSQL(filters: String) -> String {
        """
        SELECT
            \(MessageRow.selection),
            1 AS threadCount,
            (CASE WHEN m.isSeen THEN 0 ELSE 1 END) AS threadUnreadCount,
            mb.displayName AS mailboxName,
            m.accountId AS accountId
        FROM (
            SELECT
                messageSearch.rowid AS hitId,
                bm25(messageSearch, 10.0, 3.0, 1.0, 8.0) AS score,
                candidate.sentAt AS hitSentAt
            FROM messageSearch
            JOIN message candidate ON candidate.id = messageSearch.rowid
            WHERE messageSearch MATCH :match\(filters)
            ORDER BY score, hitSentAt DESC, hitId DESC
            LIMIT :limit OFFSET :offset
        ) hit
        JOIN message m ON m.id = hit.hitId
        JOIN mailbox mb ON mb.id = m.mailboxId
        ORDER BY hit.score, m.sentAt DESC, m.id DESC
        """
    }

    /// The filters-only shape: newest first, the window taken before the row is built for the
    /// same reason as the ranked one.
    private static func chronologicalSQL(filters: String) -> String {
        """
        SELECT
            \(MessageRow.selection),
            1 AS threadCount,
            (CASE WHEN m.isSeen THEN 0 ELSE 1 END) AS threadUnreadCount,
            mb.displayName AS mailboxName,
            m.accountId AS accountId
        FROM (
            SELECT candidate.id AS hitId
            FROM message candidate
            WHERE 1 = 1\(filters)
            ORDER BY candidate.sentAt DESC, candidate.id DESC
            LIMIT :limit OFFSET :offset
        ) hit
        JOIN message m ON m.id = hit.hitId
        JOIN mailbox mb ON mb.id = m.mailboxId
        ORDER BY m.sentAt DESC, m.id DESC
        """
    }

    // MARK: - Scope

    /// The scope's `AND` clause. In the search statement it sits inside the window
    /// subquery, where it narrows the rows that get scored; the coverage statement uses the
    /// same alias so the two can never disagree about what a scope means.
    ///
    /// Its bound value is ``scopeId(_:)``, and the two are read together: a scope added to
    /// one and not the other is a query that silently ignores the control the user just used.
    static func scopeSQL(_ scope: SearchQuery.Scope) -> String {
        switch scope {
        case .mailbox: "\n      AND candidate.mailboxId = :scopeId"
        case .account: "\n      AND candidate.accountId = :scopeId"
        case .all: ""
        }
    }

    /// The same scope, expressed against `mailbox` rather than `message`, for the count of
    /// what is not mirrored. A mailbox scope has nothing to say — you are already inside one.
    static func mailboxScopeSQL(_ scope: SearchQuery.Scope) -> String {
        switch scope {
        case .mailbox: " AND 0 = 1"
        case .account: " AND accountId = :scopeId"
        case .all: ""
        }
    }

    /// Nil for `.all`, which binds `:scopeId` to NULL for a statement that never names it.
    /// GRDB accepts a named argument the SQL does not use, and this relies on it — the
    /// alternative is building the dictionary in two branches.
    static func scopeId(_ scope: SearchQuery.Scope) -> Int64? {
        switch scope {
        case .mailbox(let id), .account(let id): id
        case .all: nil
        }
    }

    // MARK: - Filters

    /// The yes/no narrowings. No bound values: these are constants, not user input.
    ///
    /// "To me" is a correlated lookup on `messageAddress`'s primary key `(messageId, kind)`
    /// against the candidate's own account address and that account's aliases, so each
    /// account's mail is checked against its own identities and nobody else's.
    private static func flagSQL(_ flags: SearchQuery.FlagFilter?) -> String {
        guard let flags, !flags.isEmpty else { return "" }
        var clauses: [String] = []
        if flags.unreadOnly { clauses.append("candidate.isSeen = 0") }
        if flags.starredOnly { clauses.append("candidate.isFlagged = 1") }
        if flags.withAttachmentsOnly { clauses.append("candidate.hasAttachments = 1") }
        if flags.importantOnly { clauses.append("candidate.isImportant = 1") }
        if flags.mentionsMeOnly { clauses.append("candidate.mentionsMe = 1") }
        if flags.toMeOnly {
            clauses.append(
                """
                EXISTS (
                        SELECT 1 FROM messageAddress me
                         WHERE me.messageId = candidate.id AND me.kind = 'to'
                           AND (me.email = (SELECT emailAddress FROM account WHERE id = candidate.accountId) COLLATE NOCASE
                                OR me.email COLLATE NOCASE IN (SELECT email FROM alias WHERE accountId = candidate.accountId)))
                """
            )
        }
        return clauses.map { "\n      AND " + $0 }.joined()
    }

    /// The sheet's valued fields, each binding its values under generated names.
    ///
    /// Addresses go through `idxAddressEmail` (`email COLLATE NOCASE`), so each one is an
    /// index lookup that yields the matching message ids; the date bounds are range terms on
    /// `sentAt`, which the scope's `(…, sentAt)` index serves in a mailbox or account scope.
    /// Tags are resolved by label to tag ids, then to messages through `messageTag`.
    private static func parameterSQL(
        _ parameters: SearchQuery.Parameters,
        values: inout [String: (any DatabaseValueConvertible)?]
    ) -> String {
        var clauses: [String] = []
        if let after = parameters.sentAfter {
            values["sentAfter"] = after
            clauses.append("candidate.sentAt >= :sentAfter")
        }
        if let before = parameters.sentBefore {
            values["sentBefore"] = before
            clauses.append("candidate.sentAt < :sentBefore")
        }
        if let from = SearchQuery.Parameters.normalized(parameters.from) {
            values["from"] = from
            clauses.append(
                "candidate.id IN (SELECT messageId FROM messageAddress WHERE email = :from COLLATE NOCASE AND kind = 'from')"
            )
        }
        for (kind, addresses) in [(AddressKind.to, parameters.to), (.cc, parameters.cc), (.bcc, parameters.bcc)] {
            let names = bind(SearchQuery.Parameters.normalized(addresses), prefix: kind.rawValue, into: &values)
            guard !names.isEmpty else { continue }
            clauses.append(
                """
                candidate.id IN (SELECT messageId FROM messageAddress \
                WHERE email COLLATE NOCASE IN (\(names)) AND kind = '\(kind.rawValue)')
                """
            )
        }
        let tagNames = bind(SearchQuery.Parameters.normalized(parameters.tags), prefix: "tag", into: &values)
        if !tagNames.isEmpty {
            clauses.append(
                """
                candidate.id IN (SELECT mt.messageId FROM messageTag mt \
                JOIN tag t ON t.id = mt.tagId WHERE t.imapLabel IN (\(tagNames)))
                """
            )
        }
        return clauses.map { "\n      AND " + $0 }.joined()
    }

    /// Binds each value as `:<prefix><index>` and returns the comma-separated parameter list.
    private static func bind(
        _ items: [String],
        prefix: String,
        into values: inout [String: (any DatabaseValueConvertible)?]
    ) -> String {
        items.enumerated().map { index, item in
            let name = "\(prefix)\(index)"
            values[name] = item
            return ":" + name
        }
        .joined(separator: ", ")
    }
}
