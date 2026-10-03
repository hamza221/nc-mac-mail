// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `serverResult`: one server-computed answer, cached per ADR-0067.
///
/// `kind` names the result family (threadSummary, smartReply, translation, itinerary,
/// eventData, quota, …) and `key` is kind-specific — it embeds whatever scope the kind needs,
/// an account id, a message id, a language pair. The fetcher actor in `NCMailSync` writes
/// these; views observe them and show pending until the row exists. Expiry is the owning
/// feature's policy, applied against `fetchedAt`.
public struct ServerResultRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "serverResult"

    public var id: Int64?
    public var loginId: Int64
    public var kind: String
    public var key: String
    public var payloadJSON: String
    public var fetchedAt: Int64

    public init(id: Int64? = nil, loginId: Int64, kind: String, key: String, payloadJSON: String, fetchedAt: Int64) {
        self.id = id
        self.loginId = loginId
        self.kind = kind
        self.key = key
        self.payloadJSON = payloadJSON
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `recipientSuggestion`: what `GET /api/autoComplete` returned for one term, in
/// rank order — the server supplement to local-first autocomplete (ADR-0072).
///
/// `email` is nullable because a Nextcloud group suggestion has no single address; the
/// composer expands it from `payloadJSON` when picked.
public struct RecipientSuggestionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "recipientSuggestion"

    public var id: Int64?
    public var loginId: Int64
    public var term: String
    public var position: Int
    public var email: String?
    public var label: String?
    public var source: String?
    public var payloadJSON: String
    public var fetchedAt: Int64

    public init(
        id: Int64? = nil,
        loginId: Int64,
        term: String,
        position: Int,
        email: String? = nil,
        label: String? = nil,
        source: String? = nil,
        payloadJSON: String = "{}",
        fetchedAt: Int64
    ) {
        self.id = id
        self.loginId = loginId
        self.term = term
        self.position = position
        self.email = email
        self.label = label
        self.source = source
        self.payloadJSON = payloadJSON
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `filesListing`: one Files folder listing, cached for the save/attach pickers.
public struct FilesListingRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "filesListing"

    public var id: Int64?
    public var loginId: Int64
    public var path: String
    public var entriesJSON: String
    public var fetchedAt: Int64

    public init(id: Int64? = nil, loginId: Int64, path: String, entriesJSON: String, fetchedAt: Int64) {
        self.id = id
        self.loginId = loginId
        self.path = path
        self.entriesJSON = entriesJSON
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `smartPickerResult`: one Smart Picker provider search; the payload is the
/// result list as the OCS endpoint returned it.
public struct SmartPickerResultRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "smartPickerResult"

    public var id: Int64?
    public var loginId: Int64
    public var providerId: String
    public var term: String
    public var payloadJSON: String
    public var fetchedAt: Int64

    public init(
        id: Int64? = nil, loginId: Int64, providerId: String, term: String, payloadJSON: String, fetchedAt: Int64
    ) {
        self.id = id
        self.loginId = loginId
        self.providerId = providerId
        self.term = term
        self.payloadJSON = payloadJSON
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
