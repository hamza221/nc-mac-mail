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

    /// Ranked hits for `query`, best first.
    ///
    /// Empty or whitespace-only text returns no results rather than every message, and so
    /// does text the tokeniser would keep nothing of — a lone `-`, a bracket, an emoji.
    /// ``FTS5MatchExpression/build(from:)`` answers nil for all of them and this returns
    /// early.
    ///
    /// Nothing here touches the network, and it could not: `NCMailStore` cannot see
    /// `NCMailNet`. Search is a read of the mirror, which is what
    /// [ADR-0011](../../../../docs/decisions/0011-fts5-standalone-index.md) and the mirror
    /// itself exist for.
    public func search(_ query: SearchQuery, limit: Int, offset: Int = 0) async throws -> [SearchResult] {
        try await dbQueue.read { db in
            try Self.fetchResults(db, query: query, range: offset..<(offset + limit))
        }
    }

    /// The same query, live: a value now and another whenever a matching row changes.
    ///
    /// A message deleted locally leaves the results on the next value, because the trigger
    /// that removes its index row
    /// ([ADR-0024](../../../../docs/decisions/0024-fts-deletes-in-a-trigger.md)) is a write
    /// GRDB's observation sees.
    public func observeSearch(
        _ query: SearchQuery,
        range: Range<Int> = MailStore.defaultSearchWindow
    ) -> StoreObservation<[SearchResult]> {
        observation { db in
            try Self.fetchResults(db, query: query, range: range)
        }
    }

    /// The same rows, shaped as list rows.
    ///
    /// The message list windows over a `(Range<Int>) -> StoreObservation<[MessageRow]>`, and
    /// this is what gets installed there, so search results replace the list rather than
    /// becoming a second one. It drops `mailboxName` and `accountId`, which the list row does
    /// not draw; a caller that needs them wants ``observeSearch(_:range:)``.
    public func observeSearchRows(_ query: SearchQuery, range: Range<Int>) -> StoreObservation<[MessageRow]> {
        observation { db in
            guard let arguments = Self.searchArguments(query: query, range: range) else { return [] }
            return try MessageRow.fetchAll(db, sql: Self.searchSQL(query), arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Coverage

    /// How much of the scope has its body in the index, for the footer that says so.
    public func searchCoverage(scope: SearchQuery.Scope) async throws -> SearchCoverage {
        try await dbQueue.read { db in try Self.fetchCoverage(db, scope: scope) }
    }

    /// The same counts, live, so the footer counts up during the backfill and takes itself
    /// off screen when the mirror completes.
    public func observeSearchCoverage(scope: SearchQuery.Scope) -> StoreObservation<SearchCoverage> {
        observation { db in try Self.fetchCoverage(db, scope: scope) }
    }

    // MARK: - The queries

    private static func fetchResults(_ db: Database, query: SearchQuery, range: Range<Int>) throws -> [SearchResult] {
        guard let arguments = searchArguments(query: query, range: range) else { return [] }
        return try SearchResult.fetchAll(db, sql: searchSQL(query), arguments: StatementArguments(arguments))
    }

    private static func fetchCoverage(_ db: Database, scope: SearchQuery.Scope) throws -> SearchCoverage {
        let sql = """
            SELECT
                coalesce(sum(CASE WHEN candidate.bodyState = 'present' THEN 1 ELSE 0 END), 0)
                    AS indexedMessages,
                coalesce(sum(CASE WHEN candidate.bodyState = 'failed' THEN 1 ELSE 0 END), 0)
                    AS failedMessages,
                count(*) AS totalMessages,
                (SELECT count(*) FROM mailbox WHERE isMirrored = 0\(mailboxScopeSQL(scope)))
                    AS unmirroredMailboxes
            FROM message candidate
            WHERE 1 = 1\(scopeSQL(scope))
            """
        let coverage = try SearchCoverage.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments(["scopeId": scopeId(scope)])
        )
        // An aggregate with no GROUP BY always yields exactly one row, so the fallback is
        // unreachable. It is here so this function contains no force unwrap.
        return coverage ?? SearchCoverage(indexedMessages: 0, failedMessages: 0, totalMessages: 0)
    }

    /// The one search statement, with only the scope and flag clauses varying.
    ///
    /// `bm25` weights `subject` and `people` far above `body`, which ADR-0011 asked for: a
    /// message *about* the roadmap should beat one that mentions it in a quoted reply forty
    /// lines down, and one *from* Sookie should beat one where somebody said her name.
    /// `preview` sits between them because it is the opening of the body, and an opening line
    /// is more often what a message is about than line four hundred is.
    ///
    /// bm25 returns a negative score, smaller being a better match, so a plain ascending
    /// `ORDER BY` is best first. `sentAt DESC` breaks ties, because two equally relevant
    /// messages are best offered newest first.
    ///
    /// **The window is taken before the row is built, and that is the performance of this
    /// workstream.** Ranking has to score every match — there is no index over relevance —
    /// so an unselective query at fifty thousand messages scores fifty thousand documents
    /// whatever the shape of the statement. What the subquery removes is everything else done
    /// fifty thousand times: the fourteen-column projection and the mailbox lookup now run
    /// for the fifty rows that survive. Measured on the one-character prefix that matches the
    /// whole corpus, that is 45.6 ms with both joins above the LIMIT and 34.8 ms with them
    /// below it, against a floor of 24.1 ms for the ranking alone. See `SearchPerformanceTests`.
    ///
    /// The thread columns are the flat list's: a result is one message, not a conversation.
    /// Grouping ranked hits by thread would make the count mean "messages in this thread"
    /// rather than "hits in this thread", which is the one reading a searcher would not
    /// expect.
    private static func searchSQL(_ query: SearchQuery) -> String {
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
            WHERE messageSearch MATCH :match\
        \(scopeSQL(query.scope))\(flagSQL(query.flags))
            ORDER BY score, hitSentAt DESC
            LIMIT :limit OFFSET :offset
        ) hit
        JOIN message m ON m.id = hit.hitId
        JOIN mailbox mb ON mb.id = m.mailboxId
        ORDER BY hit.score, m.sentAt DESC
        """
    }

    /// The scope's `AND` clause. In the search statement it sits inside the ranking
    /// subquery, where it narrows the rows that get scored; the coverage statement uses the
    /// same alias so the two can never disagree about what a scope means.
    ///
    /// Its bound value is ``scopeId(_:)``, and the two are read together: a scope added to
    /// one and not the other is a query that silently ignores the control the user just used.
    private static func scopeSQL(_ scope: SearchQuery.Scope) -> String {
        switch scope {
        case .mailbox: "\n      AND candidate.mailboxId = :scopeId"
        case .account: "\n      AND candidate.accountId = :scopeId"
        case .all: ""
        }
    }

    /// The same scope, expressed against `mailbox` rather than `message`, for the count of
    /// what is not mirrored. A mailbox scope has nothing to say — you are already inside one.
    private static func mailboxScopeSQL(_ scope: SearchQuery.Scope) -> String {
        switch scope {
        case .mailbox: " AND 0 = 1"
        case .account: " AND accountId = :scopeId"
        case .all: ""
        }
    }

    /// Nil for `.all`, which binds `:scopeId` to NULL for a statement that never names it.
    /// GRDB accepts a named argument the SQL does not use, and this is the one place that
    /// relies on it — the alternative is building the dictionary in two branches.
    private static func scopeId(_ scope: SearchQuery.Scope) -> Int64? {
        switch scope {
        case .mailbox(let id), .account(let id): id
        case .all: nil
        }
    }

    /// The flag narrowings. No bound values: these are constants, not user input.
    private static func flagSQL(_ flags: SearchQuery.FlagFilter?) -> String {
        guard let flags, !flags.isEmpty else { return "" }
        var clauses: [String] = []
        if flags.unreadOnly { clauses.append("candidate.isSeen = 0") }
        if flags.starredOnly { clauses.append("candidate.isFlagged = 1") }
        if flags.withAttachmentsOnly { clauses.append("candidate.hasAttachments = 1") }
        return clauses.map { "\n      AND " + $0 }.joined()
    }

    /// The bound values, or nil when there is no query to run.
    private static func searchArguments(
        query: SearchQuery,
        range: Range<Int>
    ) -> [String: (any DatabaseValueConvertible)?]? {
        guard !range.isEmpty, let match = FTS5MatchExpression.build(from: query.text) else { return nil }
        return [
            "match": match,
            "limit": range.count,
            "offset": range.lowerBound,
            "scopeId": scopeId(query.scope),
        ]
    }
}
