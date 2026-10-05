// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Projections

/// One address of one contact that matched an autocomplete term, with the display columns the
/// suggestion list shows. A contact with no address (a group, or a person with only a phone)
/// comes back once with `email` nil.
public struct ContactSuggestionRow: Sendable, Equatable {
    public var contactId: Int64
    public var addressBookId: Int64
    public var isReadOnlyBook: Bool
    public var displayName: String?
    public var givenName: String?
    public var familyName: String?
    public var nickname: String?
    public var organization: String?
    public var isGroup: Bool
    public var email: String?
    /// The address's position in the vCard, so "the first address" is well defined.
    public var emailPosition: Int?

    public init(
        contactId: Int64,
        addressBookId: Int64,
        isReadOnlyBook: Bool = false,
        displayName: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil,
        nickname: String? = nil,
        organization: String? = nil,
        isGroup: Bool = false,
        email: String? = nil,
        emailPosition: Int? = nil
    ) {
        self.contactId = contactId
        self.addressBookId = addressBookId
        self.isReadOnlyBook = isReadOnlyBook
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.isGroup = isGroup
        self.email = email
        self.emailPosition = emailPosition
    }
}

/// One mirrored member of a contact group, by its first address.
public struct ContactGroupMemberAddress: Sendable, Equatable {
    public var groupId: Int64
    public var contactId: Int64
    public var displayName: String?
    public var email: String
}

/// How often, and how lately, one address appears in mirrored mail.
public struct MailAddressStatistic: Sendable, Equatable {
    public var email: String
    /// The display name on the newest message carrying the address.
    public var label: String?
    /// Address rows across the accounts asked about: one per message and header it is in.
    public var count: Int
    public var lastSeenAt: Int64

    public init(email: String, label: String?, count: Int, lastSeenAt: Int64) {
        self.email = email
        self.label = label
        self.count = count
        self.lastSeenAt = lastSeenAt
    }
}

/// One message in "recent mail with a contact": the list columns only, never the raw JSON.
public struct RecentMailRow: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var mailboxId: Int64
    public var accountId: Int64
    public var messageId: String?
    public var subject: String?
    public var sentAt: Int64
    public var fromEmail: String?
    public var fromLabel: String?
    public var isSeen: Bool

    public init(
        id: Int64, mailboxId: Int64, accountId: Int64, messageId: String?, subject: String?, sentAt: Int64,
        fromEmail: String?, fromLabel: String?, isSeen: Bool
    ) {
        self.id = id
        self.mailboxId = mailboxId
        self.accountId = accountId
        self.messageId = messageId
        self.subject = subject
        self.sentAt = sentAt
        self.fromEmail = fromEmail
        self.fromLabel = fromLabel
        self.isSeen = isSeen
    }
}

// MARK: - Queries (WS-26, ADR-0072)

extension MailStore {
    /// Contacts of one login's enabled address books whose name, nickname, organisation or
    /// address matches every word of `text` as a prefix, one row per address.
    ///
    /// Not ``FTS5MatchExpression``: search drops one-letter terms as noise, while
    /// autocomplete must answer the first keystroke. The same safety rule holds — only letters
    /// and digits ever reach the expression, each inside a string literal.
    public func contactSuggestions(
        matching text: String, loginId: Int64, limit: Int
    ) async throws
        -> [ContactSuggestionRow]
    {
        guard let match = Self.prefixMatchExpression(text) else { return [] }
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id, c.addressBookId, b.isReadOnly, c.displayName, c.givenName, c.familyName,
                           c.nickname, c.organization, c.isGroup, e.email, e.position
                    FROM contactSearch
                    JOIN contact c ON c.id = contactSearch.rowid
                    JOIN addressBook b ON b.id = c.addressBookId
                    LEFT JOIN contactEmail e ON e.contactId = c.id
                    WHERE contactSearch MATCH ? AND b.loginId = ? AND b.isEnabled
                    LIMIT ?
                    """,
                arguments: [match, loginId, limit]
            ).map(Self.contactSuggestionRow)
        }
    }

    /// The mirrored members of some groups, each by its first address (preferred first, then
    /// vCard order). A member without an address cannot be a recipient and is left out.
    public func groupMemberAddresses(groupIds: [Int64]) async throws -> [ContactGroupMemberAddress] {
        guard !groupIds.isEmpty else { return [] }
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.groupId, c.id AS contactId, c.displayName,
                           (SELECT e.email FROM contactEmail e WHERE e.contactId = c.id
                            ORDER BY e.isPreferred DESC, e.position LIMIT 1) AS email
                    FROM contactGroupMember m
                    JOIN contact c ON c.uid = m.memberUid
                    JOIN contact g ON g.id = m.groupId AND g.addressBookId = c.addressBookId
                    WHERE m.groupId IN \(databaseQuestionMarks(count: groupIds.count))
                    ORDER BY m.groupId, c.displayName COLLATE NOCASE, c.id
                    """,
                arguments: StatementArguments(groupIds)
            ).compactMap { row in
                guard let email: String = row["email"] else { return nil }
                return ContactGroupMemberAddress(
                    groupId: row["groupId"], contactId: row["contactId"], displayName: row["displayName"], email: email)
            }
        }
    }

    /// Every distinct address in the given accounts' mirrored mail, with how often and how
    /// recently it appeared. One aggregate pass; the autocomplete keeps the answer in memory
    /// rather than scanning `messageAddress` per keystroke (ADR-0072, as built).
    public func mailAddressStatistics(accountIds: [Int64]) async throws -> [MailAddressStatistic] {
        guard !accountIds.isEmpty else { return [] }
        return try await dbQueue.read { db in
            // SQLite fills the bare `a.label` from the row that produced MAX(m.sentAt), which is
            // exactly "the name on the newest message".
            try Row.fetchAll(
                db,
                sql: """
                    SELECT a.email AS email, a.label AS label, COUNT(*) AS count, MAX(m.sentAt) AS lastSeenAt
                    FROM messageAddress a
                    JOIN message m ON m.id = a.messageId
                    WHERE m.accountId IN \(databaseQuestionMarks(count: accountIds.count))
                    GROUP BY a.email COLLATE NOCASE
                    """,
                arguments: StatementArguments(accountIds)
            ).map { row in
                MailAddressStatistic(
                    email: row["email"], label: row["label"], count: row["count"], lastSeenAt: row["lastSeenAt"])
            }
        }
    }

    /// The contacts of one login's enabled books carrying `email`, live: the contact card
    /// re-renders when a queued "Add to contact" lands locally.
    public func observeContacts(withEmail email: String, loginId: Int64) -> StoreObservation<[ContactRecord]> {
        observation { db in
            try ContactRecord.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT c.* FROM contact c
                    JOIN contactEmail e ON e.contactId = c.id
                    JOIN addressBook b ON b.id = c.addressBookId
                    WHERE e.email = ? COLLATE NOCASE AND b.loginId = ? AND b.isEnabled
                    ORDER BY c.isGroup, c.displayName COLLATE NOCASE, c.id
                    """,
                arguments: [email, loginId]
            )
        }
    }

    /// The newest messages of some accounts with `email` in any address header, newest first.
    ///
    /// The same message mirrored into two mailboxes is two rows here; the caller collapses
    /// them by `messageId`, which is why this may answer up to `limit` rows of copies.
    public func recentMail(
        withAddress email: String, accountIds: [Int64], limit: Int
    ) async throws
        -> [RecentMailRow]
    {
        guard !accountIds.isEmpty else { return [] }
        return try await dbQueue.read { db in
            try Self.fetchRecentMail(db, email: email, accountIds: accountIds, limit: limit)
        }
    }

    public func observeRecentMail(
        withAddress email: String, accountIds: [Int64], limit: Int
    )
        -> StoreObservation<[RecentMailRow]>
    {
        observation { db in
            guard !accountIds.isEmpty else { return [] }
            return try Self.fetchRecentMail(db, email: email, accountIds: accountIds, limit: limit)
        }
    }

    // MARK: Helpers

    private static func fetchRecentMail(
        _ db: Database, email: String, accountIds: [Int64], limit: Int
    ) throws
        -> [RecentMailRow]
    {
        var arguments: [any DatabaseValueConvertible] = [email]
        arguments += accountIds.map { $0 as any DatabaseValueConvertible }
        arguments.append(limit)
        return try Row.fetchAll(
            db,
            sql: """
                SELECT m.id, m.mailboxId, m.accountId, m.messageId, m.subject, m.sentAt, m.fromEmail,
                       m.fromLabel, m.isSeen
                FROM message m
                WHERE m.id IN (SELECT a.messageId FROM messageAddress a WHERE a.email = ? COLLATE NOCASE)
                  AND m.accountId IN \(databaseQuestionMarks(count: accountIds.count))
                ORDER BY m.sentAt DESC, m.id DESC
                LIMIT ?
                """,
            arguments: StatementArguments(arguments)
        ).map { row in
            RecentMailRow(
                id: row["id"], mailboxId: row["mailboxId"], accountId: row["accountId"], messageId: row["messageId"],
                subject: row["subject"], sentAt: row["sentAt"], fromEmail: row["fromEmail"],
                fromLabel: row["fromLabel"], isSeen: row["isSeen"])
        }
    }

    private static func contactSuggestionRow(_ row: Row) -> ContactSuggestionRow {
        ContactSuggestionRow(
            contactId: row[0],
            addressBookId: row[1],
            isReadOnlyBook: row[2],
            displayName: row[3],
            givenName: row[4],
            familyName: row[5],
            nickname: row[6],
            organization: row[7],
            isGroup: row[8],
            email: row[9],
            emailPosition: row[10]
        )
    }

    /// Every letter-or-digit run of `text` as a prefix phrase, AND-ed; nil when there is none.
    /// `unicode61` splits on everything else, so this is the tokeniser's own view of the input
    /// and `alice@ex` becomes `"alice"* AND "ex"*`.
    static func prefixMatchExpression(_ text: String) -> String? {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(16).map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
}
