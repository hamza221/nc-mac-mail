// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import GRDB

/// Keeps `messageSearch` in step with `message` and `messageBody`.
///
/// [ADR-0011](../../../docs/decisions/0011-fts5-standalone-index.md) chose a standalone FTS5
/// table, which means nothing in SQLite maintains it for us. Every write that touches indexed
/// text calls one of these, in the same transaction as the write itself, so there is no window
/// in which a message exists and is unsearchable.
///
/// Deletes are the exception and live in a trigger, because a message row also disappears
/// through `ON DELETE CASCADE` and no Swift call sees that happen. See ADR-0024.
///
/// The two-step "update, and insert if that changed nothing" is not an optimisation. FTS5
/// virtual tables reject `ON CONFLICT`, so there is no upsert to reach for, and a blind
/// delete-then-insert would drop the body text every time an envelope's flags changed.
enum SearchIndexWriter {
    /// Writes the three columns an envelope owns, leaving `body` as it was.
    static func indexEnvelope(
        messageId: Int64,
        subject: String?,
        preview: String?,
        people: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE messageSearch SET subject = ?, preview = ?, people = ? WHERE rowid = ?",
            arguments: [subject ?? "", preview ?? "", people, messageId]
        )
        guard db.changesCount == 0 else { return }
        try db.execute(
            sql: """
                INSERT INTO messageSearch(rowid, subject, preview, body, people)
                VALUES (?, ?, ?, '', ?)
                """,
            arguments: [messageId, subject ?? "", preview ?? "", people]
        )
    }

    /// Writes the `body` column, leaving the envelope's three as they were.
    ///
    /// The fallback rebuilds the whole row from `message` and `messageAddress`. It should never
    /// run — a body cannot be stored without its envelope, the foreign key sees to that — but a
    /// body write that silently failed to index would be invisible until a user searched for a
    /// message they could see.
    static func indexBody(messageId: Int64, text: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE messageSearch SET body = ? WHERE rowid = ?",
            arguments: [text, messageId]
        )
        guard db.changesCount == 0 else { return }
        try db.execute(
            sql: """
                INSERT INTO messageSearch(rowid, subject, preview, body, people)
                SELECT
                    m.id,
                    coalesce(m.subject, ''),
                    coalesce(m.previewText, ''),
                    :body,
                    coalesce(
                        (SELECT group_concat(
                                    CASE WHEN a.label IS NULL OR a.label = ''
                                         THEN a.email
                                         ELSE a.label || ' <' || a.email || '>' END, ' ')
                           FROM messageAddress a
                          WHERE a.messageId = m.id AND a.kind IN ('from', 'to', 'cc')),
                        '')
                FROM message m
                WHERE m.id = :id
                """,
            arguments: ["body": text, "id": messageId]
        )
    }

    /// Empties the `body` column for one account, for "Remove local copies".
    ///
    /// The envelopes stay searchable, which is the point of the control: the app keeps working
    /// and search keeps finding subjects and people.
    static func clearBodies(accountId: Int64, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE messageSearch SET body = ''
                 WHERE rowid IN (SELECT id FROM message WHERE accountId = ?)
                """,
            arguments: [accountId]
        )
    }
}
