// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import GRDB

/// The ordered list of schema versions.
///
/// The DDL is written out as SQL rather than built with GRDB's table builder because
/// `docs/reference/schema.sql` is the contract, and `MigrationTests.schemaMatchesReference`
/// diffs what this produces against that file. A generated statement could never be compared
/// to a hand-written one, and the comparison is the point: it is what stops the document and
/// the code drifting apart between two releases.
///
/// Never edit a registered migration. Add the next one. `v1` itself was changed in place
/// once, by the identity fix in ADR-0033, and only because nothing had shipped: there was
/// no installed mirror anywhere for a `v2` to migrate.
enum MailStoreMigrations {
    static let currentVersion = "v4"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: v2)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: v3)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: v4)
        }
        // Named for what it does rather than `v5`: it changes no object, so the schema stays
        // v4 and `schema.sql` describes it unchanged. GRDB runs every registered identifier a
        // mirror has not applied, in registration order, so it runs once on every mirror,
        // after `v4` has created `contactSearch`.
        migrator.registerMigration("purgeRemovedSearchPostings") { db in
            try purgeRemovedPostings(db)
        }
        return migrator
    }

    /// Purges the search-index postings that removals before this version left in the file
    /// (ADR-0105).
    ///
    /// A plain FTS5 delete appends a marker that hides a posting from queries and leaves the
    /// posting itself in `messageSearch_data` or `contactSearch_data`, where the removal's
    /// `VACUUM` copied it into the new file. `MailStore.vacuum()` now rebuilds both indexes
    /// first; this does the same once for mirrors that were vacuumed without it. A `rebuild`
    /// rewrites an index from the table's own content, which no longer holds the removed text.
    ///
    /// It runs with SQLite's page-level `secure_delete` on, so the pages the old segments
    /// occupied are zeroed as they are freed rather than left on the free list, still
    /// holding the postings, until the next removal vacuums. The connection's own setting is
    /// put back afterwards: zeroing freed pages on every ordinary write is I/O nothing needs.
    private static func purgeRemovedPostings(_ db: Database) throws {
        let pageSecureDelete = try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? 0
        try db.execute(sql: "PRAGMA secure_delete = 1")
        try db.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('rebuild')")
        try db.execute(sql: "INSERT INTO contactSearch(contactSearch) VALUES ('rebuild')")
        try db.execute(sql: "PRAGMA secure_delete = \(pageSecureDelete)")
    }

    /// Keep in step with `docs/reference/schema.sql`, statement for statement.
    private static let v1 = """
        CREATE TABLE account (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            serverURL          TEXT    NOT NULL,
            loginName          TEXT    NOT NULL,
            remoteId           INTEGER NOT NULL,
            name               TEXT    NOT NULL,
            emailAddress       TEXT    NOT NULL,
            sortOrder          INTEGER NOT NULL DEFAULT 0,
            draftsMailboxId    INTEGER,
            sentMailboxId      INTEGER,
            trashMailboxId     INTEGER,
            archiveMailboxId   INTEGER,
            junkMailboxId      INTEGER,
            snoozeMailboxId    INTEGER,
            showSubscribedOnly INTEGER NOT NULL DEFAULT 0,
            quotaPercentage    INTEGER,
            signature          TEXT,
            mirrorState        TEXT    NOT NULL DEFAULT 'idle',
            lastSyncAt         INTEGER,
            lastDeepReconcileAt INTEGER,
            rawJSON            TEXT    NOT NULL,
            UNIQUE (serverURL, loginName, remoteId)
        );

        CREATE TABLE mailbox (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId          INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            remoteId           INTEGER NOT NULL,
            name               TEXT    NOT NULL,
            delimiter          TEXT,
            displayName        TEXT    NOT NULL,
            specialRole        TEXT,
            specialUseJSON     TEXT    NOT NULL DEFAULT '[]',
            attributesJSON     TEXT    NOT NULL DEFAULT '[]',
            isSubscribed       INTEGER NOT NULL DEFAULT 0,
            isSelectable       INTEGER NOT NULL DEFAULT 1,
            syncInBackground   INTEGER NOT NULL DEFAULT 0,
            unreadCount        INTEGER NOT NULL DEFAULT 0,
            totalCount         INTEGER,
            cacheBuster        TEXT,
            isMirrored         INTEGER NOT NULL DEFAULT 0,
            envelopeCursor     INTEGER,
            envelopesComplete  INTEGER NOT NULL DEFAULT 0,
            bodiesComplete     INTEGER NOT NULL DEFAULT 0,
            lastSyncAt         INTEGER,
            lastPrimedAt       INTEGER,
            syncFailureCount   INTEGER NOT NULL DEFAULT 0,
            lastSyncError      TEXT,
            rawJSON            TEXT    NOT NULL
        );

        CREATE INDEX idxMailboxAccount   ON mailbox(accountId);
        CREATE INDEX idxMailboxMirrored  ON mailbox(isMirrored, envelopesComplete, bodiesComplete);
        CREATE UNIQUE INDEX idxMailboxAccountName ON mailbox(accountId, name);
        CREATE UNIQUE INDEX idxMailboxAccountRemote ON mailbox(accountId, remoteId);

        CREATE TABLE message (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            remoteId       INTEGER NOT NULL,
            mailboxId      INTEGER NOT NULL REFERENCES mailbox(id) ON DELETE CASCADE,
            accountId      INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            uid            INTEGER,
            messageId      TEXT,
            threadRootId   TEXT,
            inReplyTo      TEXT,
            referencesJSON TEXT,
            subject        TEXT,
            previewText    TEXT,
            summary        TEXT,
            sentAt         INTEGER NOT NULL,
            isSeen         INTEGER NOT NULL DEFAULT 0,
            isFlagged      INTEGER NOT NULL DEFAULT 0,
            isAnswered     INTEGER NOT NULL DEFAULT 0,
            isDeleted      INTEGER NOT NULL DEFAULT 0,
            isDraft        INTEGER NOT NULL DEFAULT 0,
            isForwarded    INTEGER NOT NULL DEFAULT 0,
            isImportant    INTEGER NOT NULL DEFAULT 0,
            isJunk         INTEGER NOT NULL DEFAULT 0,
            isNotJunk      INTEGER NOT NULL DEFAULT 0,
            isMdnSent      INTEGER NOT NULL DEFAULT 0,
            hasAttachments INTEGER NOT NULL DEFAULT 0,
            mentionsMe     INTEGER NOT NULL DEFAULT 0,
            isEncrypted    INTEGER NOT NULL DEFAULT 0,
            isImipMessage  INTEGER NOT NULL DEFAULT 0,
            fromEmail      TEXT,
            fromLabel      TEXT,
            syncedAt       INTEGER NOT NULL,
            bodyState      TEXT    NOT NULL DEFAULT 'missing',
            rawJSON        TEXT    NOT NULL
        );

        CREATE INDEX idxMessageMailboxSent  ON message(mailboxId, sentAt DESC);
        CREATE INDEX idxMessageThread       ON message(mailboxId, threadRootId, sentAt DESC);
        CREATE INDEX idxMessageBodyState    ON message(accountId, bodyState, sentAt DESC);
        CREATE INDEX idxMessageMailboxSeen  ON message(mailboxId, isSeen);
        CREATE INDEX idxMessageMailboxFlagged ON message(mailboxId, isFlagged, sentAt DESC);
        CREATE INDEX idxMessageAccount      ON message(accountId, sentAt DESC);
        CREATE UNIQUE INDEX idxMessageAccountRemote ON message(accountId, remoteId);

        CREATE TABLE messageAddress (
            messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
            kind      TEXT    NOT NULL,
            position  INTEGER NOT NULL,
            email     TEXT    NOT NULL,
            label     TEXT,
            PRIMARY KEY (messageId, kind, position)
        ) WITHOUT ROWID;

        CREATE INDEX idxAddressEmail ON messageAddress(email COLLATE NOCASE);

        CREATE TABLE messageBody (
            messageId                INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
            hasHtmlBody              INTEGER NOT NULL DEFAULT 0,
            html                     TEXT,
            plainBody                TEXT,
            signature                TEXT,
            isSenderTrusted          INTEGER NOT NULL DEFAULT 0,
            dkimValid                INTEGER,
            smimeJSON                TEXT,
            phishingJSON             TEXT,
            schedulingJSON           TEXT,
            itinerariesJSON          TEXT,
            unsubscribeUrl           TEXT,
            unsubscribeMailto        TEXT,
            isOneClickUnsubscribe    INTEGER NOT NULL DEFAULT 0,
            dispositionNotificationTo TEXT,
            hasAiGeneratedHeader     INTEGER NOT NULL DEFAULT 0,
            fetchedAt                INTEGER NOT NULL,
            byteSize                 INTEGER NOT NULL DEFAULT 0,
            sanitiserGeneration      INTEGER NOT NULL DEFAULT 1,
            rawJSON                  TEXT NOT NULL
        );

        CREATE TABLE attachment (
            messageId       INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
            attachmentId    TEXT    NOT NULL,
            isInline        INTEGER NOT NULL DEFAULT 0,
            fileName        TEXT,
            mime            TEXT,
            size            INTEGER,
            cid             TEXT,
            disposition     TEXT,
            isImage         INTEGER NOT NULL DEFAULT 0,
            isCalendarEvent INTEGER NOT NULL DEFAULT 0,
            downloadUrl     TEXT,
            data            BLOB,
            fetchedAt       INTEGER,
            PRIMARY KEY (messageId, attachmentId)
        );

        CREATE INDEX idxAttachmentCid ON attachment(messageId, cid);

        CREATE TABLE tag (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId   INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            remoteId    INTEGER NOT NULL,
            imapLabel   TEXT NOT NULL,
            displayName TEXT NOT NULL,
            color       TEXT,
            UNIQUE (accountId, remoteId),
            UNIQUE (accountId, imapLabel)
        );

        CREATE TABLE messageTag (
            messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
            tagId     INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
            PRIMARY KEY (messageId, tagId)
        );

        CREATE TABLE avatar (
            email     TEXT PRIMARY KEY,
            data      BLOB,
            mime      TEXT,
            isExternal INTEGER NOT NULL DEFAULT 0,
            missing   INTEGER NOT NULL DEFAULT 0,
            fetchedAt INTEGER NOT NULL
        );

        CREATE TABLE pendingOperation (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            kind         TEXT    NOT NULL,
            accountId    INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            messageId    INTEGER,
            threadRootId TEXT,
            mailboxId    INTEGER,
            payloadJSON  TEXT    NOT NULL,
            createdAt    INTEGER NOT NULL,
            baseSyncedAt INTEGER NOT NULL,
            state        TEXT    NOT NULL DEFAULT 'pending',
            attempts     INTEGER NOT NULL DEFAULT 0,
            nextAttemptAt INTEGER,
            lastError    TEXT
        );

        CREATE INDEX idxPendingReady   ON pendingOperation(state, nextAttemptAt);
        CREATE INDEX idxPendingMessage ON pendingOperation(messageId);

        CREATE VIRTUAL TABLE messageSearch USING fts5(
            subject,
            preview,
            body,
            people,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER messageSearchDelete AFTER DELETE ON message BEGIN
            DELETE FROM messageSearch WHERE rowid = old.id;
        END;

        CREATE TABLE meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """

    /// Everything v2 adds: drafts and outbox, account settings, the `login` identity and the
    /// instance flags on it, server-state settings tables, cached server results (ADR-0067),
    /// the contacts mirror with its FTS index, calendars, teams, and snooze.
    ///
    /// Column-level choices that a reader could question:
    ///
    /// - `login` is new in v2 and is backfilled from the accounts already mirrored, so a
    ///   database migrated mid-life has a row for every signed-in identity (ADR-0079).
    /// - The account PATCH settings become columns on `account` via ALTER TABLE, which SQLite
    ///   renders into `sqlite_master` after the last column and before the UNIQUE constraint —
    ///   `schema.sql` lists them in exactly that position. The server's `order` field already
    ///   lives in v1's `sortOrder` and is not duplicated.
    /// - The appendix flags (allow-new-accounts, disable-snooze, …) are instance-wide, not
    ///   per-account — confirmed by WS-16 against the live server — so they live on `login`,
    ///   nullable: NULL means "not discovered yet", and the UI treats the feature as on.
    /// - Server-numbered rows follow ADR-0033: local `id`, server's in `remoteId`, unique per
    ///   scope. Teams keep a TEXT `remoteId` because a circle's `singleId` is a string.
    /// - Rows that only ever reference another server's object (quick action steps, aliases'
    ///   certificates, outbox aliases) carry the *remote* id of the referenced object, because
    ///   the referenced row may not be mirrored yet and the mapping is one join at read time.
    /// - No table is WITHOUT ROWID: every one of these can be observed by a view (ADR-0025).
    /// - `sieveState` deliberately has no password column. Credentials live in the Keychain;
    ///   this table holds the connection settings, the script and the parsed JSON only.
    /// - `contactSearch` is maintained like `messageSearch`: inserts and updates by the
    ///   contact DAO in the same transaction, deletes by trigger (ADR-0024).
    private static let v2 = """
        CREATE TABLE login (
            id                              INTEGER PRIMARY KEY AUTOINCREMENT,
            serverURL                       TEXT    NOT NULL,
            loginName                       TEXT    NOT NULL,
            allowNewAccounts                INTEGER,
            disableScheduledSend            INTEGER,
            disableSnooze                   INTEGER,
            llmSummariesAvailable           INTEGER,
            llmTranslationEnabled           INTEGER,
            llmFreepromptAvailable          INTEGER,
            llmFollowupAvailable            INTEGER,
            contextChatAvailable            INTEGER,
            importanceClassificationDefault INTEGER,
            enableSystemOutOfOffice         INTEGER,
            attachmentSizeLimit             INTEGER,
            googleOauthUrl                  TEXT,
            microsoftOauthUrl               TEXT,
            flagsFetchedAt                  INTEGER,
            UNIQUE (serverURL, loginName)
        );

        INSERT INTO login (serverURL, loginName)
            SELECT DISTINCT serverURL, loginName FROM account;

        ALTER TABLE account ADD COLUMN editorMode TEXT;
        ALTER TABLE account ADD COLUMN signatureAboveQuote INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE account ADD COLUMN trashRetentionDays INTEGER;
        ALTER TABLE account ADD COLUMN searchBody INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE account ADD COLUMN classificationEnabled INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE account ADD COLUMN imipCreate INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE account ADD COLUMN sieveEnabled INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE account ADD COLUMN signatureMode INTEGER;
        ALTER TABLE account ADD COLUMN smimeCertificateRemoteId INTEGER;
        ALTER TABLE account ADD COLUMN outOfOfficeFollowsSystem INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE account ADD COLUMN provisioningId INTEGER;
        ALTER TABLE account ADD COLUMN isDelegated INTEGER NOT NULL DEFAULT 0;

        CREATE TABLE alias (
            id                       INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId                INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            remoteId                 INTEGER NOT NULL,
            email                    TEXT    NOT NULL,
            name                     TEXT,
            signature                TEXT,
            provisioned              INTEGER NOT NULL DEFAULT 0,
            smimeCertificateRemoteId INTEGER,
            rawJSON                  TEXT    NOT NULL,
            UNIQUE (accountId, remoteId)
        );

        CREATE TABLE draft (
            id                       INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId                INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            remoteId                 INTEGER,
            aliasId                  INTEGER REFERENCES alias(id) ON DELETE SET NULL,
            subject                  TEXT,
            bodyPlain                TEXT,
            bodyHtml                 TEXT,
            editorBody               TEXT,
            isHtml                   INTEGER NOT NULL DEFAULT 1,
            inReplyToMessageId       TEXT,
            smimeSign                INTEGER NOT NULL DEFAULT 0,
            smimeEncrypt             INTEGER NOT NULL DEFAULT 0,
            smimeCertificateRemoteId INTEGER,
            requestMdn               INTEGER NOT NULL DEFAULT 0,
            isPgpMime                INTEGER NOT NULL DEFAULT 0,
            isAiGenerated            INTEGER NOT NULL DEFAULT 0,
            sendAt                   INTEGER,
            createdAt                INTEGER NOT NULL,
            updatedAt                INTEGER NOT NULL,
            savedAt                  INTEGER,
            syncError                TEXT
        );

        CREATE INDEX idxDraftAccount ON draft(accountId, updatedAt DESC);

        CREATE TABLE draftRecipient (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            draftId  INTEGER NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
            kind     TEXT    NOT NULL,
            position INTEGER NOT NULL,
            email    TEXT    NOT NULL,
            label    TEXT,
            UNIQUE (draftId, kind, position)
        );

        CREATE TABLE draftAttachment (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            draftId            INTEGER NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
            kind               TEXT    NOT NULL DEFAULT 'local',
            fileName           TEXT    NOT NULL,
            mime               TEXT,
            size               INTEGER,
            localPath          TEXT,
            remoteAttachmentId INTEGER,
            payloadJSON        TEXT    NOT NULL DEFAULT '{}'
        );

        CREATE INDEX idxDraftAttachmentDraft ON draftAttachment(draftId);

        CREATE TABLE outboxMessage (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId          INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            remoteId           INTEGER NOT NULL,
            aliasRemoteId      INTEGER,
            subject            TEXT,
            bodyPlain          TEXT,
            bodyHtml           TEXT,
            isHtml             INTEGER NOT NULL DEFAULT 1,
            inReplyToMessageId TEXT,
            smimeSign          INTEGER NOT NULL DEFAULT 0,
            smimeEncrypt       INTEGER NOT NULL DEFAULT 0,
            requestMdn         INTEGER NOT NULL DEFAULT 0,
            sendAt             INTEGER,
            failed             INTEGER NOT NULL DEFAULT 0,
            recipientsJSON     TEXT    NOT NULL DEFAULT '[]',
            attachmentsJSON    TEXT    NOT NULL DEFAULT '[]',
            syncedAt           INTEGER NOT NULL,
            rawJSON            TEXT    NOT NULL,
            UNIQUE (accountId, remoteId)
        );

        CREATE TABLE preference (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId   INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            key       TEXT    NOT NULL,
            value     TEXT,
            fetchedAt INTEGER NOT NULL,
            UNIQUE (loginId, key)
        );

        CREATE TABLE textBlock (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId  INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            remoteId INTEGER NOT NULL,
            title    TEXT    NOT NULL,
            content  TEXT    NOT NULL,
            isShared INTEGER NOT NULL DEFAULT 0,
            ownerId  TEXT,
            rawJSON  TEXT    NOT NULL,
            UNIQUE (loginId, remoteId)
        );

        CREATE TABLE textBlockShare (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            textBlockId INTEGER NOT NULL REFERENCES textBlock(id) ON DELETE CASCADE,
            remoteId    INTEGER,
            shareWith   TEXT    NOT NULL,
            type        TEXT    NOT NULL,
            displayName TEXT,
            rawJSON     TEXT    NOT NULL,
            UNIQUE (textBlockId, type, shareWith)
        );

        CREATE TABLE quickAction (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            remoteId  INTEGER NOT NULL,
            name      TEXT    NOT NULL,
            rawJSON   TEXT    NOT NULL,
            UNIQUE (accountId, remoteId)
        );

        CREATE TABLE quickActionStep (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            quickActionId   INTEGER NOT NULL REFERENCES quickAction(id) ON DELETE CASCADE,
            remoteId        INTEGER NOT NULL,
            name            TEXT    NOT NULL,
            position        INTEGER NOT NULL,
            tagRemoteId     INTEGER,
            mailboxRemoteId INTEGER,
            rawJSON         TEXT    NOT NULL,
            UNIQUE (quickActionId, remoteId)
        );

        CREATE TABLE trustedSender (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId  INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            remoteId INTEGER,
            email    TEXT    NOT NULL,
            type     TEXT    NOT NULL,
            UNIQUE (loginId, type, email)
        );

        CREATE TABLE internalAddress (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId  INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            remoteId INTEGER,
            address  TEXT    NOT NULL,
            type     TEXT    NOT NULL,
            UNIQUE (loginId, type, address)
        );

        CREATE TABLE delegation (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            accountId   INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            userId      TEXT    NOT NULL,
            displayName TEXT,
            rawJSON     TEXT    NOT NULL,
            UNIQUE (accountId, userId)
        );

        CREATE TABLE smimeCertificate (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId       INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            remoteId      INTEGER NOT NULL,
            emailAddress  TEXT    NOT NULL,
            hasPrivateKey INTEGER NOT NULL DEFAULT 0,
            notAfter      INTEGER,
            canSign       INTEGER NOT NULL DEFAULT 0,
            canEncrypt    INTEGER NOT NULL DEFAULT 0,
            infoJSON      TEXT    NOT NULL DEFAULT '{}',
            rawJSON       TEXT    NOT NULL,
            UNIQUE (loginId, remoteId)
        );

        CREATE TABLE sieveState (
            accountId       INTEGER PRIMARY KEY REFERENCES account(id) ON DELETE CASCADE,
            sieveEnabled    INTEGER NOT NULL DEFAULT 0,
            sieveHost       TEXT,
            sievePort       INTEGER,
            sieveUser       TEXT,
            sieveSslMode    TEXT,
            script          TEXT,
            scriptName      TEXT,
            filtersJSON     TEXT,
            outOfOfficeJSON TEXT,
            fetchedAt       INTEGER NOT NULL
        );

        CREATE TABLE serverResult (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            kind        TEXT    NOT NULL,
            key         TEXT    NOT NULL,
            payloadJSON TEXT    NOT NULL,
            fetchedAt   INTEGER NOT NULL,
            UNIQUE (loginId, kind, key)
        );

        CREATE TABLE recipientSuggestion (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            term        TEXT    NOT NULL,
            position    INTEGER NOT NULL,
            email       TEXT,
            label       TEXT,
            source      TEXT,
            payloadJSON TEXT    NOT NULL,
            fetchedAt   INTEGER NOT NULL,
            UNIQUE (loginId, term, position)
        );

        CREATE TABLE filesListing (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            path        TEXT    NOT NULL,
            entriesJSON TEXT    NOT NULL,
            fetchedAt   INTEGER NOT NULL,
            UNIQUE (loginId, path)
        );

        CREATE TABLE smartPickerResult (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            providerId  TEXT    NOT NULL,
            term        TEXT    NOT NULL,
            payloadJSON TEXT    NOT NULL,
            fetchedAt   INTEGER NOT NULL,
            UNIQUE (loginId, providerId, term)
        );

        CREATE TABLE addressBook (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            url         TEXT    NOT NULL,
            displayName TEXT,
            isReadOnly  INTEGER NOT NULL DEFAULT 0,
            isEnabled   INTEGER NOT NULL DEFAULT 1,
            position    INTEGER NOT NULL DEFAULT 0,
            syncToken   TEXT,
            lastSyncAt  INTEGER,
            UNIQUE (loginId, url)
        );

        CREATE TABLE contact (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            addressBookId INTEGER NOT NULL REFERENCES addressBook(id) ON DELETE CASCADE,
            href          TEXT    NOT NULL,
            etag          TEXT,
            uid           TEXT,
            vcard         TEXT    NOT NULL,
            displayName   TEXT,
            givenName     TEXT,
            familyName    TEXT,
            nickname      TEXT,
            organization  TEXT,
            isGroup       INTEGER NOT NULL DEFAULT 0,
            isFavorite    INTEGER NOT NULL DEFAULT 0,
            syncedAt      INTEGER NOT NULL,
            UNIQUE (addressBookId, href)
        );

        CREATE INDEX idxContactUid ON contact(uid);
        CREATE INDEX idxContactDisplayName ON contact(addressBookId, displayName COLLATE NOCASE);

        CREATE TABLE contactEmail (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            contactId   INTEGER NOT NULL REFERENCES contact(id) ON DELETE CASCADE,
            position    INTEGER NOT NULL,
            email       TEXT    NOT NULL,
            type        TEXT,
            isPreferred INTEGER NOT NULL DEFAULT 0,
            UNIQUE (contactId, position)
        );

        CREATE INDEX idxContactEmailAddress ON contactEmail(email COLLATE NOCASE);

        CREATE TABLE contactPhone (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            contactId   INTEGER NOT NULL REFERENCES contact(id) ON DELETE CASCADE,
            position    INTEGER NOT NULL,
            number      TEXT    NOT NULL,
            type        TEXT,
            isPreferred INTEGER NOT NULL DEFAULT 0,
            UNIQUE (contactId, position)
        );

        CREATE TABLE contactGroupMember (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            groupId   INTEGER NOT NULL REFERENCES contact(id) ON DELETE CASCADE,
            memberUid TEXT    NOT NULL,
            UNIQUE (groupId, memberUid)
        );

        CREATE INDEX idxContactGroupMemberUid ON contactGroupMember(memberUid);

        CREATE VIRTUAL TABLE contactSearch USING fts5(
            name,
            emails,
            organization,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER contactSearchDelete AFTER DELETE ON contact BEGIN
            DELETE FROM contactSearch WHERE rowid = old.id;
        END;

        CREATE TABLE calendar (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId        INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            url            TEXT    NOT NULL,
            displayName    TEXT,
            color          TEXT,
            isWritable     INTEGER NOT NULL DEFAULT 1,
            supportsEvents INTEGER NOT NULL DEFAULT 1,
            supportsTasks  INTEGER NOT NULL DEFAULT 0,
            position       INTEGER NOT NULL DEFAULT 0,
            fetchedAt      INTEGER NOT NULL,
            UNIQUE (loginId, url)
        );

        CREATE TABLE team (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
            remoteId    TEXT    NOT NULL,
            displayName TEXT    NOT NULL,
            rawJSON     TEXT    NOT NULL,
            fetchedAt   INTEGER NOT NULL,
            UNIQUE (loginId, remoteId)
        );

        CREATE TABLE teamMember (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            teamId      INTEGER NOT NULL REFERENCES team(id) ON DELETE CASCADE,
            userId      TEXT    NOT NULL,
            displayName TEXT,
            email       TEXT,
            rawJSON     TEXT    NOT NULL,
            UNIQUE (teamId, userId)
        );

        CREATE TABLE snooze (
            messageId INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
            until     INTEGER NOT NULL
        );

        CREATE INDEX idxSnoozeUntil ON snooze(until);
        """

    /// Everything v3 adds, all on `draft`, all nullable, all ALTER TABLE columns — so
    /// `schema.sql` lists them after `syncError`, where SQLite renders them:
    ///
    /// - `sendState`: the drafts engine's local send intent; NULL for a draft nobody has asked
    ///   to send.
    /// - `sendRequestedAt`: when the user asked, unix seconds.
    /// - `replacesMessageId`: the mirrored IMAP remote id of the Drafts-folder copy this draft
    ///   supersedes. `POST /api/drafts` and `/api/outbox` take it as `draftId`, an IMAP message
    ///   id the server expunges once the new copy lands.
    private static let v3 = """
        ALTER TABLE draft ADD COLUMN sendState TEXT;
        ALTER TABLE draft ADD COLUMN sendRequestedAt INTEGER;
        ALTER TABLE draft ADD COLUMN replacesMessageId INTEGER;
        """

    /// Everything v4 adds, for the contacts and calendar mirror, all ALTER TABLE columns — so
    /// `schema.sql` lists them after each table's last v1 column, where SQLite renders them:
    ///
    /// - `addressBook.sharedBy`: the book's `oc:owner-principal` when it is not the login's own
    ///   principal (e.g. `principals/users/alice`); NULL for the login's own book.
    /// - `calendar.isDefaultSchedule`: the login's default calendar for scheduling
    ///   (CalDAV `schedule-default-calendar-URL`). At most one per login by convention; no
    ///   constraint enforces it.
    private static let v4 = """
        ALTER TABLE addressBook ADD COLUMN sharedBy TEXT;
        ALTER TABLE calendar ADD COLUMN isDefaultSchedule INTEGER NOT NULL DEFAULT 0;
        """
}
