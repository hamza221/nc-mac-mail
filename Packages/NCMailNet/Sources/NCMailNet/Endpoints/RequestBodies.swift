// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `POST /api/mailboxes/{id}/sync`.
///
/// `ids` is a window, not an inventory: the server treats anything outside it
/// and newer than the oldest `sentAt` among them as new, and reports as vanished
/// only ids you sent. ADR-0015.
public struct SyncRequest: Encodable, Sendable {
    /// The message ids the client believes are in this mailbox.
    public var ids: [Int]
    /// Only read when the user's sort order is oldest-first; sent always, so a
    /// server that starts honouring it does not need a client change.
    public var lastMessageTimestamp: Int?
    /// True re-primes the server's IMAP cache. The answer to a 428.
    public var initialise: Bool
    public var sortOrder: String
    public var query: String?

    public init(
        ids: [Int],
        lastMessageTimestamp: Int? = nil,
        initialise: Bool = false,
        sortOrder: String = "newest",
        query: String? = nil
    ) {
        self.ids = ids
        self.lastMessageTimestamp = lastMessageTimestamp
        self.initialise = initialise
        self.sortOrder = sortOrder
        self.query = query
    }

    private enum CodingKeys: String, CodingKey {
        case ids
        case lastMessageTimestamp
        // `init` is a Swift keyword, so the property is spelled out and mapped.
        case initialise = "init"
        case sortOrder
        case query
    }
}

/// `PUT /api/messages/{id}/flags`.
///
/// The setter's keys are not the envelope's keys: it takes `junk`, `notjunk` and
/// `mdnsent` where the envelope reports `$junk`, `$notjunk` and `$mdnsent`. Send
/// only the flags being changed; the server leaves the rest alone.
public struct SetFlagsRequest: Encodable, Sendable {
    public var flags: [String: Bool]

    public init(flags: [String: Bool]) {
        self.flags = flags
    }

    public init(seen: Bool? = nil, flagged: Bool? = nil, junk: Bool? = nil, important: Bool? = nil) {
        var flags: [String: Bool] = [:]
        if let seen { flags["seen"] = seen }
        if let flagged { flags["flagged"] = flagged }
        if let junk {
            flags["junk"] = junk
            flags["notjunk"] = !junk
        }
        if let important { flags["important"] = important }
        self.flags = flags
    }

    private enum CodingKeys: String, CodingKey {
        case flags
    }
}

/// `POST /api/messages/{id}/move`. The parameter is `destFolderId` here and
/// `destMailboxId` on the thread route: same concept, same value, two spellings.
public struct MoveMessageRequest: Encodable, Sendable {
    public var destFolderId: Int

    public init(destFolderId: Int) {
        self.destFolderId = destFolderId
    }

    private enum CodingKeys: String, CodingKey {
        case destFolderId
    }
}

/// `POST /api/thread/{id}`. See ``MoveMessageRequest`` for the naming.
public struct MoveThreadRequest: Encodable, Sendable {
    public var destMailboxId: Int

    public init(destMailboxId: Int) {
        self.destMailboxId = destMailboxId
    }

    private enum CodingKeys: String, CodingKey {
        case destMailboxId
    }
}
