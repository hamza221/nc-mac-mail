// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Address books

extension MailStore {
    /// Reconciles the address book list with what CardDAV just enumerated, and answers with
    /// the rows as they now stand.
    ///
    /// Not a blind replace, because three columns are not the server's: `syncToken` and
    /// `lastSyncAt` are mirror bookkeeping — losing them would force a full re-sync of every
    /// book on every listing refresh — and `isEnabled` is the user's toggle. A book the
    /// server no longer lists is deleted, and its contacts cascade.
    @discardableResult
    public func syncAddressBooks(_ books: [AddressBookRecord], loginId: Int64) async throws -> [AddressBookRecord] {
        try await dbQueue.write { db in
            let urls = books.map(\.url)
            if urls.isEmpty {
                try db.execute(sql: "DELETE FROM addressBook WHERE loginId = ?", arguments: [loginId])
            } else {
                // `databaseQuestionMarks` already parenthesises: "(?,?,…)".
                let placeholders = databaseQuestionMarks(count: urls.count)
                try db.execute(
                    sql: "DELETE FROM addressBook WHERE loginId = ? AND url NOT IN \(placeholders)",
                    arguments: StatementArguments([loginId] + urls.map { $0 as (any DatabaseValueConvertible) })
                )
            }
            for book in books {
                try db.execute(
                    sql: """
                        INSERT INTO addressBook (loginId, url, displayName, isReadOnly, isEnabled, position)
                        VALUES (:loginId, :url, :displayName, :isReadOnly, :isEnabled, :position)
                        ON CONFLICT (loginId, url) DO UPDATE SET
                            displayName = excluded.displayName,
                            isReadOnly = excluded.isReadOnly,
                            position = excluded.position
                        """,
                    arguments: [
                        "loginId": loginId,
                        "url": book.url,
                        "displayName": book.displayName,
                        "isReadOnly": book.isReadOnly,
                        "isEnabled": book.isEnabled,
                        "position": book.position,
                    ]
                )
            }
            return try AddressBookRecord.fetchAll(
                db,
                sql: "SELECT * FROM addressBook WHERE loginId = ? ORDER BY position, displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }

    /// Stamps a completed `sync-collection` round: the token to resume from, and when.
    public func setAddressBookSyncToken(_ token: String?, lastSyncAt: Int64, addressBookId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE addressBook SET syncToken = ?, lastSyncAt = ? WHERE id = ?",
                arguments: [token, lastSyncAt, addressBookId]
            )
        }
    }

    /// The user's include-this-book toggle, which is local state and survives every sync.
    public func setAddressBookEnabled(_ enabled: Bool, addressBookId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE addressBook SET isEnabled = ? WHERE id = ?",
                arguments: [enabled, addressBookId]
            )
        }
    }

    public func addressBooks(loginId: Int64) async throws -> [AddressBookRecord] {
        try await dbQueue.read { db in
            try AddressBookRecord.fetchAll(
                db,
                sql: "SELECT * FROM addressBook WHERE loginId = ? ORDER BY position, displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }

    public func observeAddressBooks(loginId: Int64) -> StoreObservation<[AddressBookRecord]> {
        observation { db in
            try AddressBookRecord.fetchAll(
                db,
                sql: "SELECT * FROM addressBook WHERE loginId = ? ORDER BY position, displayName COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }
}

// MARK: - Contacts

extension MailStore {
    /// Writes one card and everything derived from it — the emails, the phones, the group
    /// members, the search row — in one transaction, and answers with the row.
    ///
    /// `(addressBookId, href)` finds an existing row, so a card updated on the server keeps
    /// its local id and every observation of it fires. The children are rewritten rather than
    /// merged because the vCard is authoritative: whatever it says now is the whole truth
    /// (same argument as v1's address rewrite).
    ///
    /// The search row is a delete-and-insert, unlike `messageSearch`'s column-wise update:
    /// every indexed column comes from this one write, so there is no previously stored text
    /// to preserve (ADR-0024 still owns the deletes that happen behind Swift's back).
    @discardableResult
    public func upsert(
        contact: ContactRecord,
        emails: [ContactEmailRecord] = [],
        phones: [ContactPhoneRecord] = [],
        memberUids: [String] = []
    ) async throws -> ContactRecord {
        try await dbQueue.write { db in
            var row = contact
            row.id = nil
            try row.upsert(db)
            guard
                let contactId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM contact WHERE addressBookId = ? AND href = ?",
                    arguments: [contact.addressBookId, contact.href]
                )
            else {
                throw MailStoreError.rowVanished(table: "contact", remoteId: contact.addressBookId)
            }
            row.id = contactId

            try db.execute(sql: "DELETE FROM contactEmail WHERE contactId = ?", arguments: [contactId])
            for email in emails {
                var child = email
                child.id = nil
                child.contactId = contactId
                try child.insert(db)
            }
            try db.execute(sql: "DELETE FROM contactPhone WHERE contactId = ?", arguments: [contactId])
            for phone in phones {
                var child = phone
                child.id = nil
                child.contactId = contactId
                try child.insert(db)
            }
            try db.execute(sql: "DELETE FROM contactGroupMember WHERE groupId = ?", arguments: [contactId])
            for memberUid in memberUids {
                var child = ContactGroupMemberRecord(groupId: contactId, memberUid: memberUid)
                try child.insert(db)
            }

            let name = [row.displayName, row.givenName, row.familyName, row.nickname]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            try db.execute(sql: "DELETE FROM contactSearch WHERE rowid = ?", arguments: [contactId])
            try db.execute(
                sql: "INSERT INTO contactSearch(rowid, name, emails, organization) VALUES (?, ?, ?, ?)",
                arguments: [contactId, name, emails.map(\.email).joined(separator: " "), row.organization ?? ""]
            )
            return row
        }
    }

    /// Removes one card by the identity CardDAV reports deletions under. The children cascade
    /// and the trigger takes the search row.
    public func deleteContact(addressBookId: Int64, href: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM contact WHERE addressBookId = ? AND href = ?",
                arguments: [addressBookId, href]
            )
        }
    }

    public func contact(id: Int64) async throws -> ContactRecord? {
        try await dbQueue.read { db in
            try ContactRecord.fetchOne(db, sql: "SELECT * FROM contact WHERE id = ?", arguments: [id])
        }
    }

    /// One book's cards, people and groups alike, in list order.
    public func contacts(addressBookId: Int64) async throws -> [ContactRecord] {
        try await dbQueue.read { db in
            try ContactRecord.fetchAll(
                db,
                sql: "SELECT * FROM contact WHERE addressBookId = ? ORDER BY displayName COLLATE NOCASE, id",
                arguments: [addressBookId]
            )
        }
    }

    public func observeContacts(addressBookId: Int64) -> StoreObservation<[ContactRecord]> {
        observation { db in
            try ContactRecord.fetchAll(
                db,
                sql: "SELECT * FROM contact WHERE addressBookId = ? ORDER BY displayName COLLATE NOCASE, id",
                arguments: [addressBookId]
            )
        }
    }

    public func observeContact(id: Int64) -> StoreObservation<ContactRecord?> {
        observation { db in
            try ContactRecord.fetchOne(db, sql: "SELECT * FROM contact WHERE id = ?", arguments: [id])
        }
    }

    public func contactEmails(contactId: Int64) async throws -> [ContactEmailRecord] {
        try await dbQueue.read { db in
            try ContactEmailRecord.fetchAll(
                db,
                sql: "SELECT * FROM contactEmail WHERE contactId = ? ORDER BY position",
                arguments: [contactId]
            )
        }
    }

    public func contactPhones(contactId: Int64) async throws -> [ContactPhoneRecord] {
        try await dbQueue.read { db in
            try ContactPhoneRecord.fetchAll(
                db,
                sql: "SELECT * FROM contactPhone WHERE contactId = ? ORDER BY position",
                arguments: [contactId]
            )
        }
    }

    /// A group's members that are mirrored, resolved through `contact.uid`. A member whose
    /// card has not arrived yet is simply not in the answer, and will be once it lands.
    public func members(ofGroup groupId: Int64) async throws -> [ContactRecord] {
        try await dbQueue.read { db in
            try ContactRecord.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM contact c
                    JOIN contactGroupMember m ON m.memberUid = c.uid
                    WHERE m.groupId = ?
                    ORDER BY c.displayName COLLATE NOCASE, c.id
                    """,
                arguments: [groupId]
            )
        }
    }

    /// The cards carrying one address, for the sender card and avatar resolution. Only
    /// enabled books answer, because disabling a book is supposed to hide its people.
    public func contacts(withEmail email: String) async throws -> [ContactRecord] {
        try await dbQueue.read { db in
            try ContactRecord.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT c.* FROM contact c
                    JOIN contactEmail e ON e.contactId = c.id
                    JOIN addressBook b ON b.id = c.addressBookId
                    WHERE e.email = ? COLLATE NOCASE AND b.isEnabled
                    ORDER BY c.displayName COLLATE NOCASE, c.id
                    """,
                arguments: [email]
            )
        }
    }
}
