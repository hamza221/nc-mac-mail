// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Aliases

extension MailStore {
    /// Replaces one account's aliases with the listing the server just returned.
    ///
    /// Replace rather than upsert, here and in every settings list below: the server owns
    /// every column, the lists are tens of rows, and a row deleted on the server must
    /// disappear here. Where a child table hangs off the list (text block shares, quick
    /// action steps), the call answers with the inserted rows so the caller has the local
    /// ids the children need.
    public func replaceAliases(_ aliases: [AliasRecord], accountId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM alias WHERE accountId = ?", arguments: [accountId])
            for alias in aliases {
                var row = alias
                row.id = nil
                row.accountId = accountId
                try row.insert(db)
            }
        }
    }

    public func aliases(accountId: Int64) async throws -> [AliasRecord] {
        try await dbQueue.read { db in
            try AliasRecord.fetchAll(
                db,
                sql: "SELECT * FROM alias WHERE accountId = ? ORDER BY remoteId",
                arguments: [accountId]
            )
        }
    }

    public func observeAliases(accountId: Int64) -> StoreObservation<[AliasRecord]> {
        observation { db in
            try AliasRecord.fetchAll(
                db,
                sql: "SELECT * FROM alias WHERE accountId = ? ORDER BY remoteId",
                arguments: [accountId]
            )
        }
    }
}

// MARK: - Preferences

extension MailStore {
    /// Writes one preference, which is also the grain `PUT /api/preferences/{key}` works at.
    public func setPreference(key: String, value: String?, loginId: Int64, fetchedAt: Int64) async throws {
        try await dbQueue.write { db in
            var row = PreferenceRecord(loginId: loginId, key: key, value: value, fetchedAt: fetchedAt)
            try row.upsert(db)
        }
    }

    public func preferenceValue(key: String, loginId: Int64) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM preference WHERE loginId = ? AND key = ?",
                arguments: [loginId, key]
            )
        }
    }

    public func observePreferenceValue(key: String, loginId: Int64) -> StoreObservation<String?> {
        observation { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM preference WHERE loginId = ? AND key = ?",
                arguments: [loginId, key]
            )
        }
    }
}

// MARK: - Text blocks

extension MailStore {
    /// Replaces one login's text blocks — own and shared-with-me — and answers with the rows,
    /// because shares reference their block by local id.
    @discardableResult
    public func replaceTextBlocks(_ blocks: [TextBlockRecord], loginId: Int64) async throws -> [TextBlockRecord] {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM textBlock WHERE loginId = ?", arguments: [loginId])
            return try blocks.map { block in
                var row = block
                row.id = nil
                row.loginId = loginId
                try row.insert(db)
                return row
            }
        }
    }

    public func replaceTextBlockShares(_ shares: [TextBlockShareRecord], textBlockId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM textBlockShare WHERE textBlockId = ?", arguments: [textBlockId])
            for share in shares {
                var row = share
                row.id = nil
                row.textBlockId = textBlockId
                try row.insert(db)
            }
        }
    }

    public func textBlocks(loginId: Int64) async throws -> [TextBlockRecord] {
        try await dbQueue.read { db in
            try TextBlockRecord.fetchAll(
                db,
                sql: "SELECT * FROM textBlock WHERE loginId = ? ORDER BY isShared, title COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }

    public func textBlockShares(textBlockId: Int64) async throws -> [TextBlockShareRecord] {
        try await dbQueue.read { db in
            try TextBlockShareRecord.fetchAll(
                db,
                sql: "SELECT * FROM textBlockShare WHERE textBlockId = ? ORDER BY type, shareWith",
                arguments: [textBlockId]
            )
        }
    }

    /// Every share of a login's own blocks, keyed by the block's local id, each list in
    /// `textBlockShares(textBlockId:)` order. Blocks without shares have no entry.
    public func observeTextBlockShares(loginId: Int64) -> StoreObservation<[Int64: [TextBlockShareRecord]]> {
        observation { db in
            let shares = try TextBlockShareRecord.fetchAll(
                db,
                sql: """
                    SELECT textBlockShare.* FROM textBlockShare
                    JOIN textBlock ON textBlock.id = textBlockShare.textBlockId
                    WHERE textBlock.loginId = ?
                    ORDER BY textBlockShare.textBlockId, textBlockShare.type, textBlockShare.shareWith
                    """,
                arguments: [loginId]
            )
            return Dictionary(grouping: shares, by: \.textBlockId)
        }
    }

    public func observeTextBlocks(loginId: Int64) -> StoreObservation<[TextBlockRecord]> {
        observation { db in
            try TextBlockRecord.fetchAll(
                db,
                sql: "SELECT * FROM textBlock WHERE loginId = ? ORDER BY isShared, title COLLATE NOCASE",
                arguments: [loginId]
            )
        }
    }
}

// MARK: - Quick actions

extension MailStore {
    /// Replaces one account's quick actions and answers with the rows, because steps
    /// reference their action by local id.
    @discardableResult
    public func replaceQuickActions(
        _ actions: [QuickActionRecord], accountId: Int64
    ) async throws -> [QuickActionRecord] {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM quickAction WHERE accountId = ?", arguments: [accountId])
            return try actions.map { action in
                var row = action
                row.id = nil
                row.accountId = accountId
                try row.insert(db)
                return row
            }
        }
    }

    public func replaceQuickActionSteps(_ steps: [QuickActionStepRecord], quickActionId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM quickActionStep WHERE quickActionId = ?", arguments: [quickActionId])
            for step in steps {
                var row = step
                row.id = nil
                row.quickActionId = quickActionId
                try row.insert(db)
            }
        }
    }

    public func quickActions(accountId: Int64) async throws -> [QuickActionRecord] {
        try await dbQueue.read { db in
            try QuickActionRecord.fetchAll(
                db,
                sql: "SELECT * FROM quickAction WHERE accountId = ? ORDER BY name COLLATE NOCASE",
                arguments: [accountId]
            )
        }
    }

    /// One action's steps in execution order, which is `position`.
    public func quickActionSteps(quickActionId: Int64) async throws -> [QuickActionStepRecord] {
        try await dbQueue.read { db in
            try QuickActionStepRecord.fetchAll(
                db,
                sql: "SELECT * FROM quickActionStep WHERE quickActionId = ? ORDER BY position",
                arguments: [quickActionId]
            )
        }
    }

    public func observeQuickActions(accountId: Int64) -> StoreObservation<[QuickActionRecord]> {
        observation { db in
            try QuickActionRecord.fetchAll(
                db,
                sql: "SELECT * FROM quickAction WHERE accountId = ? ORDER BY name COLLATE NOCASE",
                arguments: [accountId]
            )
        }
    }

    /// Every step of one account's quick actions, keyed by the action's local id, each
    /// list in `position` order. Actions without steps have no entry.
    public func quickActionSteps(accountId: Int64) async throws -> [Int64: [QuickActionStepRecord]] {
        try await dbQueue.read { db in try Self.fetchQuickActionSteps(db, accountId: accountId) }
    }

    /// Tracks both `quickAction` and `quickActionStep`, so step row effects, action
    /// deletes, and `replaceQuickActionSteps` all fire it.
    public func observeQuickActionSteps(accountId: Int64) -> StoreObservation<[Int64: [QuickActionStepRecord]]> {
        observation { db in try Self.fetchQuickActionSteps(db, accountId: accountId) }
    }

    private static func fetchQuickActionSteps(
        _ db: Database, accountId: Int64
    ) throws -> [Int64: [QuickActionStepRecord]] {
        let steps = try QuickActionStepRecord.fetchAll(
            db,
            sql: """
                SELECT quickActionStep.* FROM quickActionStep
                JOIN quickAction ON quickAction.id = quickActionStep.quickActionId
                WHERE quickAction.accountId = ?
                ORDER BY quickActionStep.quickActionId, quickActionStep.position
                """,
            arguments: [accountId]
        )
        return Dictionary(grouping: steps, by: \.quickActionId)
    }
}

// MARK: - Trusted senders and internal addresses

extension MailStore {
    public func replaceTrustedSenders(_ senders: [TrustedSenderRecord], loginId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM trustedSender WHERE loginId = ?", arguments: [loginId])
            for sender in senders {
                var row = sender
                row.id = nil
                row.loginId = loginId
                try row.insert(db)
            }
        }
    }

    public func trustedSenders(loginId: Int64) async throws -> [TrustedSenderRecord] {
        try await dbQueue.read { db in
            try TrustedSenderRecord.fetchAll(
                db,
                sql: "SELECT * FROM trustedSender WHERE loginId = ? ORDER BY type, email",
                arguments: [loginId]
            )
        }
    }

    public func observeTrustedSenders(loginId: Int64) -> StoreObservation<[TrustedSenderRecord]> {
        observation { db in
            try TrustedSenderRecord.fetchAll(
                db,
                sql: "SELECT * FROM trustedSender WHERE loginId = ? ORDER BY type, email",
                arguments: [loginId]
            )
        }
    }

    /// Whether remote images may load for a sender: trusted individually, or by its domain.
    ///
    /// The domain row stores the bare domain (`example.org`), matching what
    /// `PUT /api/trustedsenders/{email}?type=domain` takes, so the check peels the domain off
    /// the address here rather than storing a pattern.
    public func isSenderTrusted(email: String, loginId: Int64) async throws -> Bool {
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        return try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM trustedSender
                         WHERE loginId = :loginId
                           AND (
                                (type = 'individual' AND email = :email COLLATE NOCASE)
                             OR (type = 'domain' AND email = :domain COLLATE NOCASE)
                           )
                    )
                    """,
                arguments: ["loginId": loginId, "email": email, "domain": domain]
            ) ?? false
        }
    }

    public func replaceInternalAddresses(_ addresses: [InternalAddressRecord], loginId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM internalAddress WHERE loginId = ?", arguments: [loginId])
            for address in addresses {
                var row = address
                row.id = nil
                row.loginId = loginId
                try row.insert(db)
            }
        }
    }

    public func internalAddresses(loginId: Int64) async throws -> [InternalAddressRecord] {
        try await dbQueue.read { db in
            try InternalAddressRecord.fetchAll(
                db,
                sql: "SELECT * FROM internalAddress WHERE loginId = ? ORDER BY type, address",
                arguments: [loginId]
            )
        }
    }

    public func observeInternalAddresses(loginId: Int64) -> StoreObservation<[InternalAddressRecord]> {
        observation { db in
            try InternalAddressRecord.fetchAll(
                db,
                sql: "SELECT * FROM internalAddress WHERE loginId = ? ORDER BY type, address",
                arguments: [loginId]
            )
        }
    }

    /// Whether an address is internal — individually, or by its domain — so the message view
    /// can skip the external-sender marking.
    public func isAddressInternal(email: String, loginId: Int64) async throws -> Bool {
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        return try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM internalAddress
                         WHERE loginId = :loginId
                           AND (
                                (type = 'individual' AND address = :email COLLATE NOCASE)
                             OR (type = 'domain' AND address = :domain COLLATE NOCASE)
                           )
                    )
                    """,
                arguments: ["loginId": loginId, "email": email, "domain": domain]
            ) ?? false
        }
    }
}

// MARK: - Delegation

extension MailStore {
    public func replaceDelegations(_ delegations: [DelegationRecord], accountId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM delegation WHERE accountId = ?", arguments: [accountId])
            for delegation in delegations {
                var row = delegation
                row.id = nil
                row.accountId = accountId
                try row.insert(db)
            }
        }
    }

    public func delegations(accountId: Int64) async throws -> [DelegationRecord] {
        try await dbQueue.read { db in
            try DelegationRecord.fetchAll(
                db,
                sql: "SELECT * FROM delegation WHERE accountId = ? ORDER BY userId",
                arguments: [accountId]
            )
        }
    }

    public func observeDelegations(accountId: Int64) -> StoreObservation<[DelegationRecord]> {
        observation { db in
            try DelegationRecord.fetchAll(
                db,
                sql: "SELECT * FROM delegation WHERE accountId = ? ORDER BY userId",
                arguments: [accountId]
            )
        }
    }
}

// MARK: - S/MIME certificates

extension MailStore {
    public func replaceSmimeCertificates(_ certificates: [SmimeCertificateRecord], loginId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM smimeCertificate WHERE loginId = ?", arguments: [loginId])
            for certificate in certificates {
                var row = certificate
                row.id = nil
                row.loginId = loginId
                try row.insert(db)
            }
        }
    }

    public func smimeCertificates(loginId: Int64) async throws -> [SmimeCertificateRecord] {
        try await dbQueue.read { db in
            try SmimeCertificateRecord.fetchAll(
                db,
                sql: "SELECT * FROM smimeCertificate WHERE loginId = ? ORDER BY emailAddress, remoteId",
                arguments: [loginId]
            )
        }
    }

    public func observeSmimeCertificates(loginId: Int64) -> StoreObservation<[SmimeCertificateRecord]> {
        observation { db in
            try SmimeCertificateRecord.fetchAll(
                db,
                sql: "SELECT * FROM smimeCertificate WHERE loginId = ? ORDER BY emailAddress, remoteId",
                arguments: [loginId]
            )
        }
    }
}

// MARK: - Sieve

extension MailStore {
    /// Writes an account's Sieve state wholesale: one row per account, server-owned.
    public func upsert(sieveState: SieveStateRecord) async throws {
        try await dbQueue.write { db in try sieveState.upsert(db) }
    }

    public func sieveState(accountId: Int64) async throws -> SieveStateRecord? {
        try await dbQueue.read { db in
            try SieveStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM sieveState WHERE accountId = ?",
                arguments: [accountId]
            )
        }
    }

    public func observeSieveState(accountId: Int64) -> StoreObservation<SieveStateRecord?> {
        observation { db in
            try SieveStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM sieveState WHERE accountId = ?",
                arguments: [accountId]
            )
        }
    }
}
