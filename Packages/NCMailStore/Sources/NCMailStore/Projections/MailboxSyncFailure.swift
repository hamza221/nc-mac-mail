// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// One mailbox whose last sync failed: how often in a row, and with what.
///
/// The app's session-expiry trigger watches these for a newly recorded `unauthorized`
/// (WS-25). Three columns of the `mailbox` table rather than the whole ``MailboxRecord``,
/// so the observation does not read the `message` table and a backfill does not wake it.
public struct MailboxSyncFailure: FetchableRecord, Decodable, Sendable, Equatable {
    public var id: Int64
    public var syncFailureCount: Int
    /// `describe(_:)`'s rendering from `NCMailSync`: a case name, never user data.
    public var lastSyncError: String

    public init(id: Int64, syncFailureCount: Int, lastSyncError: String) {
        self.id = id
        self.syncFailureCount = syncFailureCount
        self.lastSyncError = lastSyncError
    }
}
