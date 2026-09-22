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
/// Never edit a registered migration. Add the next one.
enum MailStoreMigrations {
    static let currentVersion = "v1"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        return migrator
    }

    /// Keep in step with `docs/reference/schema.sql`, statement for statement.
    private static let v1 = """
        CREATE TABLE account (
            id                 INTEGER PRIMARY KEY,
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
            rawJSON            TEXT    NOT NULL
        );

        CREATE TABLE mailbox (
            id                 INTEGER PRIMARY KEY,
            accountId          INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
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

        CREATE TABLE message (
            id             INTEGER PRIMARY KEY,
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
            id          INTEGER PRIMARY KEY,
            imapLabel   TEXT NOT NULL,
            displayName TEXT NOT NULL,
            color       TEXT,
            UNIQUE (imapLabel)
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
}
