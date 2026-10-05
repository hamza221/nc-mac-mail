// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `account`, as read.
///
/// The column names are the property names, which is why the schema is camelCase: no
/// `CodingKeys`, and a column rename is a compile error rather than a silent nil.
///
/// `id` is this mirror's own, and `remoteId` is the server's. The server's id is unique on
/// one instance only, so it identifies an account here only in company with `serverURL` and
/// `loginName` — see [ADR-0033](../../../../docs/decisions/0033-accounts-have-a-local-identity.md).
public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "account"

    public var id: Int64
    public var serverURL: String
    public var loginName: String
    public var remoteId: Int64
    public var name: String
    public var emailAddress: String
    public var sortOrder: Int
    public var draftsMailboxId: Int64?
    public var sentMailboxId: Int64?
    public var trashMailboxId: Int64?
    /// Null on a live server that has no archive folder configured, which is the common case
    /// rather than a rare one. Nothing may assume this is set.
    public var archiveMailboxId: Int64?
    public var junkMailboxId: Int64?
    public var snoozeMailboxId: Int64?
    public var showSubscribedOnly: Bool
    public var quotaPercentage: Int?
    public var signature: String?
    public var mirrorState: MirrorState
    public var lastSyncAt: Int64?
    public var lastDeepReconcileAt: Int64?
    public var rawJSON: String
    // v2 settings columns, mirrored from the account payload (WS-18). The server's
    // `order` is `sortOrder` above, not a thirteenth column.
    public var editorMode: String?
    public var signatureAboveQuote: Bool
    public var trashRetentionDays: Int?
    public var searchBody: Bool
    public var classificationEnabled: Bool
    public var imipCreate: Bool
    public var sieveEnabled: Bool
    public var signatureMode: Int?
    public var smimeCertificateRemoteId: Int64?
    public var outOfOfficeFollowsSystem: Bool
    public var provisioningId: Int64?
    public var isDelegated: Bool

    /// Where this account's credentials live, and what makes ``remoteId`` mean something.
    public var identity: ServerIdentity {
        ServerIdentity(serverURL: serverURL, loginName: loginName)
    }

    public init(
        id: Int64,
        identity: ServerIdentity,
        remoteId: Int64,
        name: String,
        emailAddress: String,
        sortOrder: Int = 0,
        draftsMailboxId: Int64? = nil,
        sentMailboxId: Int64? = nil,
        trashMailboxId: Int64? = nil,
        archiveMailboxId: Int64? = nil,
        junkMailboxId: Int64? = nil,
        snoozeMailboxId: Int64? = nil,
        showSubscribedOnly: Bool = false,
        quotaPercentage: Int? = nil,
        signature: String? = nil,
        mirrorState: MirrorState = .idle,
        lastSyncAt: Int64? = nil,
        lastDeepReconcileAt: Int64? = nil,
        rawJSON: String = "{}",
        editorMode: String? = nil,
        signatureAboveQuote: Bool = false,
        trashRetentionDays: Int? = nil,
        searchBody: Bool = false,
        classificationEnabled: Bool = false,
        imipCreate: Bool = false,
        sieveEnabled: Bool = false,
        signatureMode: Int? = nil,
        smimeCertificateRemoteId: Int64? = nil,
        outOfOfficeFollowsSystem: Bool = false,
        provisioningId: Int64? = nil,
        isDelegated: Bool = false
    ) {
        self.id = id
        serverURL = identity.serverURL
        loginName = identity.loginName
        self.remoteId = remoteId
        self.name = name
        self.emailAddress = emailAddress
        self.sortOrder = sortOrder
        self.draftsMailboxId = draftsMailboxId
        self.sentMailboxId = sentMailboxId
        self.trashMailboxId = trashMailboxId
        self.archiveMailboxId = archiveMailboxId
        self.junkMailboxId = junkMailboxId
        self.snoozeMailboxId = snoozeMailboxId
        self.showSubscribedOnly = showSubscribedOnly
        self.quotaPercentage = quotaPercentage
        self.signature = signature
        self.mirrorState = mirrorState
        self.lastSyncAt = lastSyncAt
        self.lastDeepReconcileAt = lastDeepReconcileAt
        self.rawJSON = rawJSON
        self.editorMode = editorMode
        self.signatureAboveQuote = signatureAboveQuote
        self.trashRetentionDays = trashRetentionDays
        self.searchBody = searchBody
        self.classificationEnabled = classificationEnabled
        self.imipCreate = imipCreate
        self.sieveEnabled = sieveEnabled
        self.signatureMode = signatureMode
        self.smimeCertificateRemoteId = smimeCertificateRemoteId
        self.outOfOfficeFollowsSystem = outOfOfficeFollowsSystem
        self.provisioningId = provisioningId
        self.isDelegated = isDelegated
    }
}

/// The columns of `account` the server owns, plus the identity that scopes them.
///
/// Writing this rather than a whole ``AccountRecord`` is what keeps a sync from resetting
/// `mirrorState` and `lastDeepReconcileAt` to whatever the caller happened to have in hand:
/// a column that is not in the INSERT is not in the `DO UPDATE SET` either. See ADR-0023.
///
/// No `id`. The local id is the mirror's to assign, and an upsert finds the existing row
/// through `UNIQUE (serverURL, loginName, remoteId)` instead (ADR-0033).
public struct AccountWrite: Codable, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "account"

    public var serverURL: String
    public var loginName: String
    public var remoteId: Int64
    public var name: String
    public var emailAddress: String
    public var sortOrder: Int
    public var draftsMailboxId: Int64?
    public var sentMailboxId: Int64?
    public var trashMailboxId: Int64?
    public var archiveMailboxId: Int64?
    public var junkMailboxId: Int64?
    public var snoozeMailboxId: Int64?
    public var showSubscribedOnly: Bool
    public var quotaPercentage: Int?
    public var signature: String?
    public var rawJSON: String
    // v2: the PATCH settings surface. Part of the write because every GET /api/accounts
    // payload carries them, so a sync always has real values in hand (ADR-0023 is about
    // columns the server does not own; these it does).
    public var editorMode: String?
    public var signatureAboveQuote: Bool
    public var trashRetentionDays: Int?
    public var searchBody: Bool
    public var classificationEnabled: Bool
    public var imipCreate: Bool
    public var sieveEnabled: Bool
    public var signatureMode: Int?
    public var smimeCertificateRemoteId: Int64?
    public var outOfOfficeFollowsSystem: Bool
    public var provisioningId: Int64?
    public var isDelegated: Bool

    public init(
        identity: ServerIdentity,
        remoteId: Int64,
        name: String,
        emailAddress: String,
        sortOrder: Int = 0,
        draftsMailboxId: Int64? = nil,
        sentMailboxId: Int64? = nil,
        trashMailboxId: Int64? = nil,
        archiveMailboxId: Int64? = nil,
        junkMailboxId: Int64? = nil,
        snoozeMailboxId: Int64? = nil,
        showSubscribedOnly: Bool = false,
        quotaPercentage: Int? = nil,
        signature: String? = nil,
        rawJSON: String = "{}",
        editorMode: String? = nil,
        signatureAboveQuote: Bool = false,
        trashRetentionDays: Int? = nil,
        searchBody: Bool = false,
        classificationEnabled: Bool = false,
        imipCreate: Bool = false,
        sieveEnabled: Bool = false,
        signatureMode: Int? = nil,
        smimeCertificateRemoteId: Int64? = nil,
        outOfOfficeFollowsSystem: Bool = false,
        provisioningId: Int64? = nil,
        isDelegated: Bool = false
    ) {
        serverURL = identity.serverURL
        loginName = identity.loginName
        self.remoteId = remoteId
        self.name = name
        self.emailAddress = emailAddress
        self.sortOrder = sortOrder
        self.draftsMailboxId = draftsMailboxId
        self.sentMailboxId = sentMailboxId
        self.trashMailboxId = trashMailboxId
        self.archiveMailboxId = archiveMailboxId
        self.junkMailboxId = junkMailboxId
        self.snoozeMailboxId = snoozeMailboxId
        self.showSubscribedOnly = showSubscribedOnly
        self.quotaPercentage = quotaPercentage
        self.signature = signature
        self.rawJSON = rawJSON
        self.editorMode = editorMode
        self.signatureAboveQuote = signatureAboveQuote
        self.trashRetentionDays = trashRetentionDays
        self.searchBody = searchBody
        self.classificationEnabled = classificationEnabled
        self.imipCreate = imipCreate
        self.sieveEnabled = sieveEnabled
        self.signatureMode = signatureMode
        self.smimeCertificateRemoteId = smimeCertificateRemoteId
        self.outOfOfficeFollowsSystem = outOfOfficeFollowsSystem
        self.provisioningId = provisioningId
        self.isDelegated = isDelegated
    }
}
