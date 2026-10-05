// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `login`: one signed-in Nextcloud identity, the (serverURL, loginName) pair the
/// Keychain item is keyed by.
///
/// One login has many mail accounts and one set of address books, preferences and instance
/// flags, so everything instance-scoped hangs off this row and cascades when the user signs
/// out — see [ADR-0079](../../../../docs/decisions/0079-a-login-table-roots-instance-state.md).
///
/// The flag columns are the web client's appendix flags. They are instance-wide server
/// configuration, measured by WS-16, and all nullable: nil means "not discovered yet", and
/// the UI treats the feature as available until a sync writes otherwise.
public struct LoginRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "login"

    public var id: Int64?
    public var serverURL: String
    public var loginName: String
    public var allowNewAccounts: Bool?
    public var disableScheduledSend: Bool?
    public var disableSnooze: Bool?
    public var llmSummariesAvailable: Bool?
    public var llmTranslationEnabled: Bool?
    public var llmFreepromptAvailable: Bool?
    public var llmFollowupAvailable: Bool?
    public var contextChatAvailable: Bool?
    public var importanceClassificationDefault: Bool?
    public var enableSystemOutOfOffice: Bool?
    /// Bytes. nil means no limit is known, which is also what the server means by absence.
    public var attachmentSizeLimit: Int64?
    public var googleOauthUrl: String?
    public var microsoftOauthUrl: String?
    public var flagsFetchedAt: Int64?

    /// The pair the Keychain item and every `AccountSession` are keyed by.
    public var identity: ServerIdentity {
        ServerIdentity(serverURL: serverURL, loginName: loginName)
    }

    public init(
        id: Int64? = nil,
        identity: ServerIdentity,
        allowNewAccounts: Bool? = nil,
        disableScheduledSend: Bool? = nil,
        disableSnooze: Bool? = nil,
        llmSummariesAvailable: Bool? = nil,
        llmTranslationEnabled: Bool? = nil,
        llmFreepromptAvailable: Bool? = nil,
        llmFollowupAvailable: Bool? = nil,
        contextChatAvailable: Bool? = nil,
        importanceClassificationDefault: Bool? = nil,
        enableSystemOutOfOffice: Bool? = nil,
        attachmentSizeLimit: Int64? = nil,
        googleOauthUrl: String? = nil,
        microsoftOauthUrl: String? = nil,
        flagsFetchedAt: Int64? = nil
    ) {
        self.id = id
        serverURL = identity.serverURL
        loginName = identity.loginName
        self.allowNewAccounts = allowNewAccounts
        self.disableScheduledSend = disableScheduledSend
        self.disableSnooze = disableSnooze
        self.llmSummariesAvailable = llmSummariesAvailable
        self.llmTranslationEnabled = llmTranslationEnabled
        self.llmFreepromptAvailable = llmFreepromptAvailable
        self.llmFollowupAvailable = llmFollowupAvailable
        self.contextChatAvailable = contextChatAvailable
        self.importanceClassificationDefault = importanceClassificationDefault
        self.enableSystemOutOfOffice = enableSystemOutOfOffice
        self.attachmentSizeLimit = attachmentSizeLimit
        self.googleOauthUrl = googleOauthUrl
        self.microsoftOauthUrl = microsoftOauthUrl
        self.flagsFetchedAt = flagsFetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
