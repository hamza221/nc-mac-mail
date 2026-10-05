// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Calendars

extension MailStore {
    /// Replaces one login's calendar list with what CalDAV just enumerated. Calendars carry
    /// no mirror bookkeeping — they are listed, not synced — so a plain replace is safe.
    public func replaceCalendars(_ calendars: [CalendarRecord], loginId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM calendar WHERE loginId = ?", arguments: [loginId])
            for calendar in calendars {
                var row = calendar
                row.id = nil
                row.loginId = loginId
                try row.insert(db)
            }
        }
    }

    public func calendars(loginId: Int64) async throws -> [CalendarRecord] {
        try await dbQueue.read { db in
            try CalendarRecord.fetchAll(
                db,
                sql: "SELECT * FROM calendar WHERE loginId = ? ORDER BY position, displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }

    public func observeCalendars(loginId: Int64) -> StoreObservation<[CalendarRecord]> {
        observation { db in
            try CalendarRecord.fetchAll(
                db,
                sql: "SELECT * FROM calendar WHERE loginId = ? ORDER BY position, displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }
}

// MARK: - Teams

extension MailStore {
    /// Replaces one login's teams and answers with the rows, because members reference their
    /// team by local id.
    @discardableResult
    public func replaceTeams(_ teams: [TeamRecord], loginId: Int64) async throws -> [TeamRecord] {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM team WHERE loginId = ?", arguments: [loginId])
            return try teams.map { team in
                var row = team
                row.id = nil
                row.loginId = loginId
                try row.insert(db)
                return row
            }
        }
    }

    public func replaceTeamMembers(_ members: [TeamMemberRecord], teamId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM teamMember WHERE teamId = ?", arguments: [teamId])
            for member in members {
                var row = member
                row.id = nil
                row.teamId = teamId
                try row.insert(db)
            }
        }
    }

    public func teams(loginId: Int64) async throws -> [TeamRecord] {
        try await dbQueue.read { db in
            try TeamRecord.fetchAll(
                db,
                sql: "SELECT * FROM team WHERE loginId = ? ORDER BY displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }

    public func teamMembers(teamId: Int64) async throws -> [TeamMemberRecord] {
        try await dbQueue.read { db in
            try TeamMemberRecord.fetchAll(
                db,
                sql: "SELECT * FROM teamMember WHERE teamId = ? ORDER BY displayName COLLATE NOCASE, userId",
                arguments: [teamId]
            )
        }
    }

    public func observeTeams(loginId: Int64) -> StoreObservation<[TeamRecord]> {
        observation { db in
            try TeamRecord.fetchAll(
                db,
                sql: "SELECT * FROM team WHERE loginId = ? ORDER BY displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }
}

// MARK: - Snooze

extension MailStore {
    /// Hides a message until `until`. A second snooze of the same message replaces the first —
    /// a message is snoozed once.
    public func setSnooze(until: Int64, messageId: Int64) async throws {
        try await dbQueue.write { db in
            try SnoozeRecord(messageId: messageId, until: until).upsert(db)
        }
    }

    /// Unsnoozes, by hand or by the sweep. A message that was not snoozed is not an error.
    public func clearSnooze(messageId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM snooze WHERE messageId = ?", arguments: [messageId])
        }
    }

    public func snoozeUntil(messageId: Int64) async throws -> Int64? {
        try await dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT until FROM snooze WHERE messageId = ?", arguments: [messageId])
        }
    }

    public func observeSnoozeUntil(messageId: Int64) -> StoreObservation<Int64?> {
        observation { db in
            try Int64.fetchOne(db, sql: "SELECT until FROM snooze WHERE messageId = ?", arguments: [messageId])
        }
    }

    /// The rows whose time has come, oldest first, for the sweep that wakes them.
    public func dueSnoozes(before cutoff: Int64) async throws -> [SnoozeRecord] {
        try await dbQueue.read { db in
            try SnoozeRecord.fetchAll(
                db,
                sql: "SELECT * FROM snooze WHERE until <= ? ORDER BY until",
                arguments: [cutoff]
            )
        }
    }
}
