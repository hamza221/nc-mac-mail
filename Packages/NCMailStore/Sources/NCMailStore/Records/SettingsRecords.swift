// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `alias`: a sending identity of one account.
///
/// `smimeCertificateRemoteId` is the server's certificate id, not a local row id — the
/// certificate list is mirrored separately and may not have arrived yet.
public struct AliasRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "alias"

    public var id: Int64?
    public var accountId: Int64
    public var remoteId: Int64
    public var email: String
    public var name: String?
    public var signature: String?
    public var provisioned: Bool
    public var smimeCertificateRemoteId: Int64?
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        accountId: Int64,
        remoteId: Int64,
        email: String,
        name: String? = nil,
        signature: String? = nil,
        provisioned: Bool = false,
        smimeCertificateRemoteId: Int64? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.email = email
        self.name = name
        self.signature = signature
        self.provisioned = provisioned
        self.smimeCertificateRemoteId = smimeCertificateRemoteId
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `preference`: one `GET /api/preferences/{key}` value, per login.
public struct PreferenceRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "preference"

    public var id: Int64?
    public var loginId: Int64
    public var key: String
    public var value: String?
    public var fetchedAt: Int64

    public init(id: Int64? = nil, loginId: Int64, key: String, value: String?, fetchedAt: Int64) {
        self.id = id
        self.loginId = loginId
        self.key = key
        self.value = value
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `textBlock`: a reusable snippet, own or shared with this login.
public struct TextBlockRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "textBlock"

    public var id: Int64?
    public var loginId: Int64
    public var remoteId: Int64
    public var title: String
    public var content: String
    /// Shared *with* this login, as opposed to owned by it. The two come from the same
    /// listing and only the owner's blocks can be edited or re-shared.
    public var isShared: Bool
    public var ownerId: String?
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        loginId: Int64,
        remoteId: Int64,
        title: String,
        content: String,
        isShared: Bool = false,
        ownerId: String? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.loginId = loginId
        self.remoteId = remoteId
        self.title = title
        self.content = content
        self.isShared = isShared
        self.ownerId = ownerId
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `textBlockShare`: one user or group a text block of mine is shared with.
public struct TextBlockShareRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "textBlockShare"

    public var id: Int64?
    public var textBlockId: Int64
    public var remoteId: Int64?
    public var shareWith: String
    /// user|group.
    public var type: String
    public var displayName: String?
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        textBlockId: Int64,
        remoteId: Int64? = nil,
        shareWith: String,
        type: String,
        displayName: String? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.textBlockId = textBlockId
        self.remoteId = remoteId
        self.shareWith = shareWith
        self.type = type
        self.displayName = displayName
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `quickAction`: one named chain of triage steps, per account.
public struct QuickActionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "quickAction"

    public var id: Int64?
    public var accountId: Int64
    public var remoteId: Int64
    public var name: String
    public var rawJSON: String

    public init(id: Int64? = nil, accountId: Int64, remoteId: Int64, name: String, rawJSON: String = "{}") {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.name = name
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `quickActionStep`.
///
/// `tagRemoteId` and `mailboxRemoteId` are the server's ids, as the payload speaks them;
/// the local rows are one join away when the action runs.
public struct QuickActionStepRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "quickActionStep"

    public var id: Int64?
    public var quickActionId: Int64
    public var remoteId: Int64
    /// markAsSpam|applyTag|snooze|moveThread|deleteThread|markAsRead|markAsUnread|markAsImportant|markAsFavorite.
    public var name: String
    /// The server's `order`, renamed because `order` is an SQL keyword.
    public var position: Int
    public var tagRemoteId: Int64?
    public var mailboxRemoteId: Int64?
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        quickActionId: Int64,
        remoteId: Int64,
        name: String,
        position: Int,
        tagRemoteId: Int64? = nil,
        mailboxRemoteId: Int64? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.quickActionId = quickActionId
        self.remoteId = remoteId
        self.name = name
        self.position = position
        self.tagRemoteId = tagRemoteId
        self.mailboxRemoteId = mailboxRemoteId
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `trustedSender`: an address or domain whose remote images may load.
public struct TrustedSenderRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "trustedSender"

    public var id: Int64?
    public var loginId: Int64
    public var remoteId: Int64?
    /// An address, or a bare domain when ``type`` is `domain`.
    public var email: String
    /// individual|domain.
    public var type: String

    public init(id: Int64? = nil, loginId: Int64, remoteId: Int64? = nil, email: String, type: String) {
        self.id = id
        self.loginId = loginId
        self.remoteId = remoteId
        self.email = email
        self.type = type
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `internalAddress`: an address or domain not flagged as an external sender.
public struct InternalAddressRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "internalAddress"

    public var id: Int64?
    public var loginId: Int64
    public var remoteId: Int64?
    public var address: String
    /// individual|domain.
    public var type: String

    public init(id: Int64? = nil, loginId: Int64, remoteId: Int64? = nil, address: String, type: String) {
        self.id = id
        self.loginId = loginId
        self.remoteId = remoteId
        self.address = address
        self.type = type
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `delegation`: one user an account is delegated to.
public struct DelegationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "delegation"

    public var id: Int64?
    public var accountId: Int64
    public var userId: String
    public var displayName: String?
    public var rawJSON: String

    public init(id: Int64? = nil, accountId: Int64, userId: String, displayName: String? = nil, rawJSON: String = "{}")
    {
        self.id = id
        self.accountId = accountId
        self.userId = userId
        self.displayName = displayName
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `smimeCertificate`: the parsed listing of one certificate the server holds.
///
/// Only metadata. The certificate and key bytes stay on the server; `infoJSON` keeps the
/// parsed subject/issuer/purposes blob for the settings table view.
public struct SmimeCertificateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "smimeCertificate"

    public var id: Int64?
    public var loginId: Int64
    public var remoteId: Int64
    public var emailAddress: String
    public var hasPrivateKey: Bool
    public var notAfter: Int64?
    public var canSign: Bool
    public var canEncrypt: Bool
    public var infoJSON: String
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        loginId: Int64,
        remoteId: Int64,
        emailAddress: String,
        hasPrivateKey: Bool = false,
        notAfter: Int64? = nil,
        canSign: Bool = false,
        canEncrypt: Bool = false,
        infoJSON: String = "{}",
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.loginId = loginId
        self.remoteId = remoteId
        self.emailAddress = emailAddress
        self.hasPrivateKey = hasPrivateKey
        self.notAfter = notAfter
        self.canSign = canSign
        self.canEncrypt = canEncrypt
        self.infoJSON = infoJSON
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The one row of `sieveState` an account has: connection settings, the active script, and
/// the managed section parsed into JSON.
///
/// Deliberately no password column — Sieve credentials are a Keychain item, like every other
/// credential in this app.
public struct SieveStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "sieveState"

    public var accountId: Int64
    public var sieveEnabled: Bool
    public var sieveHost: String?
    public var sievePort: Int?
    public var sieveUser: String?
    public var sieveSslMode: String?
    public var script: String?
    public var scriptName: String?
    public var filtersJSON: String?
    public var outOfOfficeJSON: String?
    public var fetchedAt: Int64

    public init(
        accountId: Int64,
        sieveEnabled: Bool = false,
        sieveHost: String? = nil,
        sievePort: Int? = nil,
        sieveUser: String? = nil,
        sieveSslMode: String? = nil,
        script: String? = nil,
        scriptName: String? = nil,
        filtersJSON: String? = nil,
        outOfOfficeJSON: String? = nil,
        fetchedAt: Int64
    ) {
        self.accountId = accountId
        self.sieveEnabled = sieveEnabled
        self.sieveHost = sieveHost
        self.sievePort = sievePort
        self.sieveUser = sieveUser
        self.sieveSslMode = sieveSslMode
        self.script = script
        self.scriptName = scriptName
        self.filtersJSON = filtersJSON
        self.outOfOfficeJSON = outOfOfficeJSON
        self.fetchedAt = fetchedAt
    }
}
