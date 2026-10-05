// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Server results (ADR-0067)

extension MailStore {
    /// Caches one server-computed answer. `(loginId, kind, key)` is the upsert target, so
    /// asking again overwrites the stale row rather than growing a second.
    public func upsert(serverResult: ServerResultRecord) async throws {
        try await dbQueue.write { db in
            var row = serverResult
            try row.upsert(db)
        }
    }

    public func serverResult(kind: String, key: String, loginId: Int64) async throws -> ServerResultRecord? {
        try await dbQueue.read { db in
            try ServerResultRecord.fetchOne(
                db,
                sql: "SELECT * FROM serverResult WHERE loginId = ? AND kind = ? AND key = ?",
                arguments: [loginId, kind, key]
            )
        }
    }

    /// The row a view waits on: nil is the pending state, a row is the answer.
    public func observeServerResult(kind: String, key: String, loginId: Int64) -> StoreObservation<ServerResultRecord?>
    {
        observation { db in
            try ServerResultRecord.fetchOne(
                db,
                sql: "SELECT * FROM serverResult WHERE loginId = ? AND kind = ? AND key = ?",
                arguments: [loginId, kind, key]
            )
        }
    }

    /// One kind's rows for many keys, across every login — a list window's batch read.
    /// Ordered by key, then login.
    public func observeServerResults(kind: String, keys: [String]) -> StoreObservation<[ServerResultRecord]> {
        observation { db in
            guard !keys.isEmpty else { return [] }
            return try ServerResultRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM serverResult
                    WHERE kind = ? AND key IN \(databaseQuestionMarks(count: keys.count))
                    ORDER BY key, loginId
                    """,
                arguments: StatementArguments([kind] + keys)
            )
        }
    }

    /// Expires one kind's rows. Each owning feature sets its own staleness policy (ADR-0067),
    /// which is why this takes the cutoff rather than knowing one.
    public func deleteServerResults(kind: String, olderThan cutoff: Int64, loginId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM serverResult WHERE loginId = ? AND kind = ? AND fetchedAt < ?",
                arguments: [loginId, kind, cutoff]
            )
        }
    }
}

// MARK: - Recipient suggestions (ADR-0072)

extension MailStore {
    /// Replaces the cached server answer for one autocomplete term, in rank order.
    public func replaceRecipientSuggestions(
        _ suggestions: [RecipientSuggestionRecord],
        term: String,
        loginId: Int64
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM recipientSuggestion WHERE loginId = ? AND term = ?",
                arguments: [loginId, term]
            )
            for (position, suggestion) in suggestions.enumerated() {
                var row = suggestion
                row.id = nil
                row.loginId = loginId
                row.term = term
                row.position = position
                try row.insert(db)
            }
        }
    }

    public func recipientSuggestions(term: String, loginId: Int64) async throws -> [RecipientSuggestionRecord] {
        try await dbQueue.read { db in
            try RecipientSuggestionRecord.fetchAll(
                db,
                sql: "SELECT * FROM recipientSuggestion WHERE loginId = ? AND term = ? ORDER BY position",
                arguments: [loginId, term]
            )
        }
    }

    public func observeRecipientSuggestions(
        term: String, loginId: Int64
    ) -> StoreObservation<[RecipientSuggestionRecord]> {
        observation { db in
            try RecipientSuggestionRecord.fetchAll(
                db,
                sql: "SELECT * FROM recipientSuggestion WHERE loginId = ? AND term = ? ORDER BY position",
                arguments: [loginId, term]
            )
        }
    }
}

// MARK: - Files listings

extension MailStore {
    public func upsert(filesListing: FilesListingRecord) async throws {
        try await dbQueue.write { db in
            var row = filesListing
            try row.upsert(db)
        }
    }

    public func filesListing(path: String, loginId: Int64) async throws -> FilesListingRecord? {
        try await dbQueue.read { db in
            try FilesListingRecord.fetchOne(
                db,
                sql: "SELECT * FROM filesListing WHERE loginId = ? AND path = ?",
                arguments: [loginId, path]
            )
        }
    }

    public func observeFilesListing(path: String, loginId: Int64) -> StoreObservation<FilesListingRecord?> {
        observation { db in
            try FilesListingRecord.fetchOne(
                db,
                sql: "SELECT * FROM filesListing WHERE loginId = ? AND path = ?",
                arguments: [loginId, path]
            )
        }
    }
}

// MARK: - Smart Picker results

extension MailStore {
    public func upsert(smartPickerResult: SmartPickerResultRecord) async throws {
        try await dbQueue.write { db in
            var row = smartPickerResult
            try row.upsert(db)
        }
    }

    public func smartPickerResult(
        providerId: String, term: String, loginId: Int64
    ) async throws -> SmartPickerResultRecord? {
        try await dbQueue.read { db in
            try SmartPickerResultRecord.fetchOne(
                db,
                sql: "SELECT * FROM smartPickerResult WHERE loginId = ? AND providerId = ? AND term = ?",
                arguments: [loginId, providerId, term]
            )
        }
    }

    public func observeSmartPickerResult(
        providerId: String,
        term: String,
        loginId: Int64
    ) -> StoreObservation<SmartPickerResultRecord?> {
        observation { db in
            try SmartPickerResultRecord.fetchOne(
                db,
                sql: "SELECT * FROM smartPickerResult WHERE loginId = ? AND providerId = ? AND term = ?",
                arguments: [loginId, providerId, term]
            )
        }
    }
}
