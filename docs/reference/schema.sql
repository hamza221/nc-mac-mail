-- SPDX-FileCopyrightText: Hamza Mahjoubi
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Canonical schema for the local mirror, version 1.
--
-- This file is the contract. `Packages/NCMailStore/Sources/NCMailStore/Migrations.swift`
-- must produce exactly this schema, and `MigrationTests.testSchemaMatchesReference`
-- asserts it by diffing `sqlite_master` against this file. Change this file and the
-- migration in the same commit, never one without the other.
--
-- Conventions
--   * Column names are camelCase so GRDB records need no CodingKeys.
--   * `id` is always local to this mirror. The server's own id is `remoteId`, and it
--     is unique on one Nextcloud instance and meaningless across two (ADR-0033).
--     `remoteId` is never the base64 `id` the mailbox payload also carries -- see
--     docs/reference/api-payloads.md.
--   * Times are INTEGER unix seconds, matching the server's `dateInt`/`sentAt`.
--   * Booleans are INTEGER 0/1.
--   * Anything the app has not modelled yet survives in a `rawJSON` column, so a
--     server that grows a field does not lose it between a sync and a schema bump.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

CREATE TABLE account (
    -- Local identity. The server's own account id is `remoteId`, which is unique on
    -- one Nextcloud instance and says nothing across two -- see ADR-0033.
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    serverURL          TEXT    NOT NULL,       -- normalised, as the Keychain item holds it
    loginName          TEXT    NOT NULL,
    remoteId           INTEGER NOT NULL,       -- server account id
    name               TEXT    NOT NULL,
    emailAddress       TEXT    NOT NULL,
    sortOrder          INTEGER NOT NULL DEFAULT 0,
    -- Special mailbox ids. Nullable: a freshly provisioned account may have none
    -- of them assigned until its first folder sync.
    draftsMailboxId    INTEGER,
    sentMailboxId      INTEGER,
    trashMailboxId     INTEGER,
    archiveMailboxId   INTEGER,
    junkMailboxId      INTEGER,
    snoozeMailboxId    INTEGER,
    showSubscribedOnly INTEGER NOT NULL DEFAULT 0,
    quotaPercentage    INTEGER,
    signature          TEXT,
    -- Mirror bookkeeping.
    mirrorState        TEXT    NOT NULL DEFAULT 'idle',   -- idle|priming|envelopes|bodies|complete|paused|failed
    lastSyncAt         INTEGER,
    lastDeepReconcileAt INTEGER,
    rawJSON            TEXT    NOT NULL,
    -- One row per Mail account per signed-in login. Two Nextcloud instances that each
    -- have an account id 1 are two rows here, not one overwritten twice.
    UNIQUE (serverURL, loginName, remoteId)
);

-- ---------------------------------------------------------------------------
-- Mailboxes
-- ---------------------------------------------------------------------------

CREATE TABLE mailbox (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,   -- local
    accountId          INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    remoteId           INTEGER NOT NULL,          -- server `databaseId`
    name               TEXT    NOT NULL,          -- full IMAP path, e.g. "INBOX.Work.2024"
    delimiter          TEXT,                      -- may be NULL on a flat namespace
    displayName        TEXT    NOT NULL,          -- last path component, decoded
    specialRole        TEXT,                      -- inbox|drafts|sent|archive|junk|trash|flagged|all|null
    specialUseJSON     TEXT    NOT NULL DEFAULT '[]',
    attributesJSON     TEXT    NOT NULL DEFAULT '[]',
    -- Derived from attributesJSON at write time; see ADR-0007.
    isSubscribed       INTEGER NOT NULL DEFAULT 0,
    isSelectable       INTEGER NOT NULL DEFAULT 1,
    syncInBackground   INTEGER NOT NULL DEFAULT 0,
    unreadCount        INTEGER NOT NULL DEFAULT 0,
    totalCount         INTEGER,
    cacheBuster        TEXT,
    -- Mirror bookkeeping, per mailbox. All of it survives a quit.
    isMirrored         INTEGER NOT NULL DEFAULT 0,   -- subscribed => mirrored
    envelopeCursor     INTEGER,                      -- exclusive upper bound for the next page:
    --                                              one past the oldest `dateInt` pulled, so a
    --                                              duplicate at a page boundary is re-read rather
    --                                              than skipped (ADR-0030)
    envelopesComplete  INTEGER NOT NULL DEFAULT 0,
    bodiesComplete     INTEGER NOT NULL DEFAULT 0,
    lastSyncAt         INTEGER,
    lastPrimedAt       INTEGER,                      -- last successful init sync against the server cache
    syncFailureCount   INTEGER NOT NULL DEFAULT 0,
    lastSyncError      TEXT,
    rawJSON            TEXT    NOT NULL
);

CREATE INDEX idxMailboxAccount   ON mailbox(accountId);
CREATE INDEX idxMailboxMirrored  ON mailbox(isMirrored, envelopesComplete, bodiesComplete);
CREATE UNIQUE INDEX idxMailboxAccountName ON mailbox(accountId, name);
-- The conflict target every mailbox upsert relies on, and what stops one server's
-- mailbox 5 overwriting another's.
CREATE UNIQUE INDEX idxMailboxAccountRemote ON mailbox(accountId, remoteId);

-- ---------------------------------------------------------------------------
-- Messages (envelopes)
-- ---------------------------------------------------------------------------

CREATE TABLE message (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,  -- local
    remoteId       INTEGER NOT NULL,              -- server `databaseId`
    mailboxId      INTEGER NOT NULL REFERENCES mailbox(id) ON DELETE CASCADE,
    accountId      INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    uid            INTEGER,                       -- IMAP UID, for diagnostics only
    messageId      TEXT,                          -- RFC 5322 Message-ID
    threadRootId   TEXT,                          -- server-computed thread key
    inReplyTo      TEXT,
    referencesJSON TEXT,
    subject        TEXT,
    previewText    TEXT,
    summary        TEXT,                          -- LLM summary, when the server has one
    sentAt         INTEGER NOT NULL,              -- `dateInt`
    -- Flags, one column each: they are all queried and sorted on.
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
    -- Denormalised sender, so the list query needs no join.
    fromEmail      TEXT,
    fromLabel      TEXT,
    -- Mirror bookkeeping.
    syncedAt       INTEGER NOT NULL,              -- when this envelope was last written
    bodyState      TEXT    NOT NULL DEFAULT 'missing', -- missing|queued|fetching|present|failed
    rawJSON        TEXT    NOT NULL
);

-- The message list query: one mailbox, newest first.
CREATE INDEX idxMessageMailboxSent  ON message(mailboxId, sentAt DESC);
-- Threaded grouping and the thread view.
CREATE INDEX idxMessageThread       ON message(mailboxId, threadRootId, sentAt DESC);
-- The body backfill picker, which asks per account and newest first. `accountId`
-- leads so the seek lands on one account's missing bodies and walks `limit` rows;
-- without it every candidate needs a table lookup to find out whose it is.
CREATE INDEX idxMessageBodyState    ON message(accountId, bodyState, sentAt DESC);
-- Unread counts and the starred filter.
CREATE INDEX idxMessageMailboxSeen  ON message(mailboxId, isSeen);
CREATE INDEX idxMessageMailboxFlagged ON message(mailboxId, isFlagged, sentAt DESC);
CREATE INDEX idxMessageAccount      ON message(accountId, sentAt DESC);
-- The conflict target every envelope upsert relies on. Unique per account, never
-- globally: `databaseId` is one server's counter.
CREATE UNIQUE INDEX idxMessageAccountRemote ON message(accountId, remoteId);

-- ---------------------------------------------------------------------------
-- Addresses
-- ---------------------------------------------------------------------------
-- Normalised because "everything from this person" and the search index both
-- need them, and because a message with forty recipients should not make forty
-- copies of the envelope row.
--
-- The only WITHOUT ROWID table left, and it stays that way because nothing
-- observes it: the list reads the denormalised sender off `message`. SQLite's
-- update hook is not called for WITHOUT ROWID tables, so GRDB's ValueObservation
-- can never fire for one. See ADR-0025.

CREATE TABLE messageAddress (
    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
    kind      TEXT    NOT NULL,   -- from|to|cc|bcc|replyTo
    position  INTEGER NOT NULL,
    email     TEXT    NOT NULL,
    label     TEXT,
    PRIMARY KEY (messageId, kind, position)
) WITHOUT ROWID;

CREATE INDEX idxAddressEmail ON messageAddress(email COLLATE NOCASE);

-- ---------------------------------------------------------------------------
-- Bodies
-- ---------------------------------------------------------------------------
-- One row per message that has been backfilled. `html` holds the SANITISED
-- fragment from `GET /api/messages/{id}/html?plain=true` -- never raw MIME, and
-- never a document with the server's iframe resizer in it. See ADR-0009.

CREATE TABLE messageBody (
    messageId                INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
    hasHtmlBody              INTEGER NOT NULL DEFAULT 0,
    html                     TEXT,
    plainBody                TEXT,
    signature                TEXT,
    isSenderTrusted          INTEGER NOT NULL DEFAULT 0,
    dkimValid                INTEGER,             -- NULL when the server did not report
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
    byteSize                 INTEGER NOT NULL DEFAULT 0,  -- for the storage panel
    sanitiserGeneration      INTEGER NOT NULL DEFAULT 1,  -- bump to force a re-download
    rawJSON                  TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- Attachments (metadata only in v1 -- payloads are fetched on demand)
-- ---------------------------------------------------------------------------

CREATE TABLE attachment (
    messageId       INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
    attachmentId    TEXT    NOT NULL,     -- server id, a string ("2", "2.1", ...)
    isInline        INTEGER NOT NULL DEFAULT 0,
    fileName        TEXT,
    mime            TEXT,
    size            INTEGER,
    cid             TEXT,
    disposition     TEXT,
    isImage         INTEGER NOT NULL DEFAULT 0,
    isCalendarEvent INTEGER NOT NULL DEFAULT 0,
    downloadUrl     TEXT,
    -- Populated only for inline images the renderer has already pulled, so a
    -- message read offline still shows its own pictures.
    data            BLOB,
    fetchedAt       INTEGER,
    PRIMARY KEY (messageId, attachmentId)
);

CREATE INDEX idxAttachmentCid ON attachment(messageId, cid);

-- ---------------------------------------------------------------------------
-- Tags (IMAP keywords)
-- ---------------------------------------------------------------------------

CREATE TABLE tag (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,  -- local
    accountId   INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    remoteId    INTEGER NOT NULL,
    imapLabel   TEXT NOT NULL,
    displayName TEXT NOT NULL,
    color       TEXT,
    -- Tags belong to an account server-side, so both keys are scoped to one.
    UNIQUE (accountId, remoteId),
    UNIQUE (accountId, imapLabel)
);

CREATE TABLE messageTag (
    messageId INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
    tagId     INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (messageId, tagId)
);

-- ---------------------------------------------------------------------------
-- Avatars
-- ---------------------------------------------------------------------------
-- Keyed by address because that is what `GET /api/avatars/image/{email}` takes.
-- `missing` records a 404 so the client does not ask again every launch; the
-- library draws coloured initials in that case and needs no bytes.

CREATE TABLE avatar (
    email     TEXT PRIMARY KEY,
    data      BLOB,
    mime      TEXT,
    isExternal INTEGER NOT NULL DEFAULT 0,
    missing   INTEGER NOT NULL DEFAULT 0,
    fetchedAt INTEGER NOT NULL
);

-- ---------------------------------------------------------------------------
-- The offline mutation queue
-- ---------------------------------------------------------------------------
-- Every triage action writes the mirror and appends here in ONE transaction.
-- The drainer is the only thing that talks to the server about mutations.
-- See docs/architecture/offline-queue.md.

CREATE TABLE pendingOperation (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    kind         TEXT    NOT NULL,   -- setFlags|move|delete|junk|markThread|moveThread|deleteThread
    accountId    INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    -- Exactly one of these is set.
    messageId    INTEGER,
    threadRootId TEXT,
    mailboxId    INTEGER,            -- the mailbox the row was in when queued
    payloadJSON  TEXT    NOT NULL,   -- the absolute intent, e.g. {"seen":true}
    createdAt    INTEGER NOT NULL,
    baseSyncedAt INTEGER NOT NULL,   -- message.syncedAt when the op was queued
    state        TEXT    NOT NULL DEFAULT 'pending', -- pending|inFlight|failed
    attempts     INTEGER NOT NULL DEFAULT 0,
    nextAttemptAt INTEGER,
    lastError    TEXT
);

CREATE INDEX idxPendingReady   ON pendingOperation(state, nextAttemptAt);
CREATE INDEX idxPendingMessage ON pendingOperation(messageId);

-- ---------------------------------------------------------------------------
-- Full text search
-- ---------------------------------------------------------------------------
-- A plain (not external-content) FTS5 table keyed by `rowid = message.id`, kept
-- in step inside the same transaction as the writes above. It stores its own
-- copy of the text, which costs disk that the mirror already committed to, and
-- buys us freedom from the contentless-table delete rules that vary by SQLite
-- version. See ADR-0011.

CREATE VIRTUAL TABLE messageSearch USING fts5(
    subject,
    preview,
    body,
    people,                     -- "Name <addr>" for from/to/cc, space joined
    tokenize = 'unicode61 remove_diacritics 2'
);

-- Inserts and updates are the store's helper, in the same transaction as the write
-- that feeds them. Deletes are not, because a message row also disappears through
-- ON DELETE CASCADE from its mailbox or its account, and a cascade is invisible to
-- the Swift code that started it. See ADR-0024.
CREATE TRIGGER messageSearchDelete AFTER DELETE ON message BEGIN
    DELETE FROM messageSearch WHERE rowid = old.id;
END;

-- ---------------------------------------------------------------------------
-- Key/value metadata
-- ---------------------------------------------------------------------------
-- Schema version is GRDB's business (`grdb_migrations`); this is for app state
-- that is not worth a table: the server URL, the login name, the cached theming
-- colour, the backfill pause flag.

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
