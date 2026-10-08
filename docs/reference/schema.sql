-- SPDX-FileCopyrightText: Hamza Mahjoubi
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Canonical schema for the local mirror, version 4. Migration
-- `purgeRemovedSearchPostings` changes no object here; it rebuilds `messageSearch` and
-- `contactSearch` once (ADR-0105).
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
--   * v2 columns on `account` appear after `rawJSON` and before the UNIQUE constraint,
--     because they were added with ALTER TABLE and that is where SQLite renders them
--     in `sqlite_master`, which this file is diffed against.

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
    -- v2: the account settings PATCH surface, mirrored from the account payload. The
    -- server's `order` is v1's `sortOrder`, not a new column.
    editorMode TEXT,                                   -- plaintext|richtext
    signatureAboveQuote INTEGER NOT NULL DEFAULT 0,
    trashRetentionDays INTEGER,                        -- NULL = server default
    searchBody INTEGER NOT NULL DEFAULT 0,
    classificationEnabled INTEGER NOT NULL DEFAULT 0,
    imipCreate INTEGER NOT NULL DEFAULT 0,
    sieveEnabled INTEGER NOT NULL DEFAULT 0,
    signatureMode INTEGER,
    smimeCertificateRemoteId INTEGER,                  -- server id of the linked certificate
    outOfOfficeFollowsSystem INTEGER NOT NULL DEFAULT 0,
    provisioningId INTEGER,                            -- non-NULL = provisioned, settings locked
    isDelegated INTEGER NOT NULL DEFAULT 0,
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
--
-- `email` is always SQLite's `lower()` of the address, written by SQL rather than
-- by Swift, and every query compares against `lower()` of its argument. No ICU, so
-- that folds ASCII only; Swift's `lowercased()` folds all of Unicode and must not
-- be mixed in (ADR-0104). Shared across accounts and outside every cascade, so
-- removing an account deletes the rows no remaining message's sender names.

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

-- A delete or update here only appends a marker that hides the old postings from
-- queries; the postings stay in `messageSearch_data` until a merge meets them.
-- So every removal ends in `MailStore.vacuum()`, which runs FTS5 `rebuild` before
-- `VACUUM`: removed mail must not stay readable in the file (ADR-0105).

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

-- ===========================================================================
-- Version 2 (WS-18): drafts and outbox, settings, server results, contacts,
-- calendars, teams, snooze. See ADR-0079 for `login` and ADR-0067 for the
-- cached-result tables.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Logins
-- ---------------------------------------------------------------------------
-- One row per signed-in Nextcloud identity -- the (serverURL, loginName) pair the
-- Keychain item is keyed by. One login has many mail accounts and one set of
-- address books, preferences and instance flags, so everything scoped to the
-- instance hangs off this row and cascades when the user signs out (ADR-0079).
--
-- The flag columns are the appendix flags from the parity matrix. They are
-- instance-wide server configuration, not account settings (measured by WS-16),
-- and they are all nullable: NULL means "not discovered yet", and the UI treats
-- the feature as available until told otherwise.

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
    attachmentSizeLimit             INTEGER,            -- bytes; NULL = no limit known
    googleOauthUrl                  TEXT,
    microsoftOauthUrl               TEXT,
    flagsFetchedAt                  INTEGER,
    UNIQUE (serverURL, loginName)
);

-- ---------------------------------------------------------------------------
-- Aliases
-- ---------------------------------------------------------------------------
-- A sending identity of one account. `smimeCertificateRemoteId` is the server's
-- certificate id, not a local row: the certificate list is mirrored separately
-- and the referenced certificate may not be mirrored yet.

CREATE TABLE alias (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    accountId                INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    remoteId                 INTEGER NOT NULL,
    email                    TEXT    NOT NULL,          -- the server's `alias`
    name                     TEXT,
    signature                TEXT,
    provisioned              INTEGER NOT NULL DEFAULT 0,
    smimeCertificateRemoteId INTEGER,
    rawJSON                  TEXT    NOT NULL,
    UNIQUE (accountId, remoteId)
);

-- ---------------------------------------------------------------------------
-- Drafts (local-first; ADR-0066)
-- ---------------------------------------------------------------------------
-- The local row is authoritative; `remoteId` is the server draft once the flush
-- has happened and `savedAt` is when. Recipients and attachments are child rows
-- because the composer edits them individually; the outbox below is a mirror and
-- keeps them as JSON.

CREATE TABLE draft (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    accountId                INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    remoteId                 INTEGER,                   -- server draft id once flushed
    aliasId                  INTEGER REFERENCES alias(id) ON DELETE SET NULL,
    subject                  TEXT,
    bodyPlain                TEXT,
    bodyHtml                 TEXT,
    editorBody               TEXT,                      -- the editor's own HTML, round-trippable
    isHtml                   INTEGER NOT NULL DEFAULT 1,
    inReplyToMessageId       TEXT,                      -- RFC 5322 Message-ID
    smimeSign                INTEGER NOT NULL DEFAULT 0,
    smimeEncrypt             INTEGER NOT NULL DEFAULT 0,
    smimeCertificateRemoteId INTEGER,
    requestMdn               INTEGER NOT NULL DEFAULT 0,
    isPgpMime                INTEGER NOT NULL DEFAULT 0,
    isAiGenerated            INTEGER NOT NULL DEFAULT 0,
    sendAt                   INTEGER,                   -- scheduled send, unix seconds
    createdAt                INTEGER NOT NULL,
    updatedAt                INTEGER NOT NULL,
    savedAt                  INTEGER,                   -- last successful server flush
    syncError                TEXT,
    -- v3 (ALTER TABLE, so rendered last): the drafts engine's send intent.
    sendState TEXT,                                    -- NULL = not requested
    sendRequestedAt INTEGER,                           -- unix seconds
    replacesMessageId INTEGER                          -- IMAP remote id of the superseded
                                                       -- Drafts-folder copy (server draftId)
);

CREATE INDEX idxDraftAccount ON draft(accountId, updatedAt DESC);

CREATE TABLE draftRecipient (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    draftId  INTEGER NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
    kind     TEXT    NOT NULL,   -- to|cc|bcc
    position INTEGER NOT NULL,
    email    TEXT    NOT NULL,
    label    TEXT,
    UNIQUE (draftId, kind, position)
);

CREATE TABLE draftAttachment (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    draftId            INTEGER NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
    kind               TEXT    NOT NULL DEFAULT 'local',   -- local|message|message-attachment|cloud
    fileName           TEXT    NOT NULL,
    mime               TEXT,
    size               INTEGER,
    localPath          TEXT,                            -- staged bytes on disk, not in the db
    remoteAttachmentId INTEGER,                         -- id from POST /api/attachments
    payloadJSON        TEXT    NOT NULL DEFAULT '{}'    -- verbatim what the send API needs
);

CREATE INDEX idxDraftAttachmentDraft ON draftAttachment(draftId);

-- ---------------------------------------------------------------------------
-- Outbox (a mirror of GET /api/outbox; the server owns these rows)
-- ---------------------------------------------------------------------------
-- Recipients and attachments stay JSON here: the outbox view only displays them,
-- and editing one goes through the draft tables after `PUT /api/outbox/{id}`.

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

-- ---------------------------------------------------------------------------
-- Settings mirrored from the server
-- ---------------------------------------------------------------------------

-- Per-user preferences (`GET /api/preferences/{key}`), scoped to the login.
CREATE TABLE preference (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId   INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    key       TEXT    NOT NULL,
    value     TEXT,
    fetchedAt INTEGER NOT NULL,
    UNIQUE (loginId, key)
);

-- Text blocks, own and shared-with-me. `isShared` marks the latter; `ownerId`
-- is who shared it.
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

-- Shares of my own text blocks. `remoteId` is nullable because the share listing
-- may identify rows by (block, shareWith) rather than an id of its own.
CREATE TABLE textBlockShare (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    textBlockId INTEGER NOT NULL REFERENCES textBlock(id) ON DELETE CASCADE,
    remoteId    INTEGER,
    shareWith   TEXT    NOT NULL,
    type        TEXT    NOT NULL,   -- user|group
    displayName TEXT,
    rawJSON     TEXT    NOT NULL,
    UNIQUE (textBlockId, type, shareWith)
);

-- Quick actions and their steps. Steps reference the tag and mailbox by the
-- server's ids: the payload speaks remote ids and the local rows are one join
-- away when the action runs.
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
    name            TEXT    NOT NULL,   -- markAsSpam|applyTag|snooze|moveThread|...
    position        INTEGER NOT NULL,   -- the server's `order`
    tagRemoteId     INTEGER,
    mailboxRemoteId INTEGER,
    rawJSON         TEXT    NOT NULL,
    UNIQUE (quickActionId, remoteId)
);

-- Trusted senders and internal addresses. The server keys both by (type, value),
-- which is the upsert target; the row id it also returns is kept but nullable.
CREATE TABLE trustedSender (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId  INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    remoteId INTEGER,
    email    TEXT    NOT NULL,   -- an address, or a bare domain for type 'domain'
    type     TEXT    NOT NULL,   -- individual|domain
    UNIQUE (loginId, type, email)
);

CREATE TABLE internalAddress (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId  INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    remoteId INTEGER,
    address  TEXT    NOT NULL,
    type     TEXT    NOT NULL,   -- individual|domain
    UNIQUE (loginId, type, address)
);

-- Who one account is delegated to.
CREATE TABLE delegation (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    accountId   INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    userId      TEXT    NOT NULL,
    displayName TEXT,
    rawJSON     TEXT    NOT NULL,
    UNIQUE (accountId, userId)
);

-- S/MIME certificates, per login (the server stores them per user and accounts
-- link to them by id). `infoJSON` keeps the parsed subject/issuer/purposes blob.
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

-- Sieve, one row per account: the connection settings (never the password --
-- that is a Keychain item), the active script, and the parsed managed section.
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

-- ---------------------------------------------------------------------------
-- Cached server-computed results (ADR-0067)
-- ---------------------------------------------------------------------------
-- The network writes a row; the view observes it and shows pending until it
-- exists. `kind` names the result family (threadSummary, smartReply, translation,
-- itinerary, eventData, quota, ...), `key` is kind-specific and embeds whatever
-- scope the kind needs (an account id, a message id, a language pair).

CREATE TABLE serverResult (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    kind        TEXT    NOT NULL,
    key         TEXT    NOT NULL,
    payloadJSON TEXT    NOT NULL,
    fetchedAt   INTEGER NOT NULL,
    UNIQUE (loginId, kind, key)
);

-- The server supplement to local-first autocomplete (ADR-0072): what
-- GET /api/autoComplete returned for one term, in rank order. `email` is
-- nullable because a group suggestion has no single address.
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

-- One Files folder listing per path, for the save/attach pickers.
CREATE TABLE filesListing (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    path        TEXT    NOT NULL,
    entriesJSON TEXT    NOT NULL,
    fetchedAt   INTEGER NOT NULL,
    UNIQUE (loginId, path)
);

-- One Smart Picker search per provider and term; the payload is the result list.
CREATE TABLE smartPickerResult (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    providerId  TEXT    NOT NULL,
    term        TEXT    NOT NULL,
    payloadJSON TEXT    NOT NULL,
    fetchedAt   INTEGER NOT NULL,
    UNIQUE (loginId, providerId, term)
);

-- ---------------------------------------------------------------------------
-- Contacts (CardDAV mirror; ADR-0069)
-- ---------------------------------------------------------------------------
-- Keyed by login, not mail account: one login has one set of address books.
-- `syncToken` is mirror bookkeeping and survives list refreshes, exactly like
-- `mailbox.envelopeCursor` does.

CREATE TABLE addressBook (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    loginId     INTEGER NOT NULL REFERENCES login(id) ON DELETE CASCADE,
    url         TEXT    NOT NULL,          -- the collection URL, CardDAV's identity
    displayName TEXT,
    isReadOnly  INTEGER NOT NULL DEFAULT 0,
    isEnabled   INTEGER NOT NULL DEFAULT 1,   -- user toggle: include in lists and autocomplete
    position    INTEGER NOT NULL DEFAULT 0,
    syncToken   TEXT,                      -- RFC 6578 token; NULL = never synced
    lastSyncAt  INTEGER,
    -- v4 (ALTER TABLE, so rendered last): oc:owner-principal of a book shared to this
    -- login, e.g. principals/users/alice; NULL = the login's own book.
    sharedBy TEXT,
    UNIQUE (loginId, url)
);

-- The raw vCard is authoritative and lossless (ADR-0069); the display columns
-- are extracted at write time so lists and sorts never parse vCards. A group is
-- a KIND:group vCard; its members are child rows below.
CREATE TABLE contact (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    addressBookId INTEGER NOT NULL REFERENCES addressBook(id) ON DELETE CASCADE,
    href          TEXT    NOT NULL,        -- resource URL within the collection
    etag          TEXT,
    uid           TEXT,                    -- vCard UID
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

-- Normalised because autocomplete joins on the address and a contact may have
-- many of either.
CREATE TABLE contactEmail (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    contactId   INTEGER NOT NULL REFERENCES contact(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    email       TEXT    NOT NULL,
    type        TEXT,                      -- HOME|WORK|... as the vCard spells it
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

-- Group membership by the member's vCard UID, not a foreign key: the member's
-- row may not have arrived yet when the group does, and deleting a member must
-- not edit the group's vCard behind CardDAV's back. Resolved by join on
-- `contact.uid`.
CREATE TABLE contactGroupMember (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    groupId   INTEGER NOT NULL REFERENCES contact(id) ON DELETE CASCADE,
    memberUid TEXT    NOT NULL,
    UNIQUE (groupId, memberUid)
);

CREATE INDEX idxContactGroupMemberUid ON contactGroupMember(memberUid);

-- Contact search, same construction as messageSearch: a plain FTS5 table keyed
-- by rowid = contact.id, written by the contact DAO in the same transaction as
-- the row, deleted by trigger because cascades are invisible to Swift (ADR-0024).
CREATE VIRTUAL TABLE contactSearch USING fts5(
    name,                       -- display, given, family, nickname, space joined
    emails,                     -- every address, space joined
    organization,
    tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER contactSearchDelete AFTER DELETE ON contact BEGIN
    DELETE FROM contactSearch WHERE rowid = old.id;
END;

-- ---------------------------------------------------------------------------
-- Calendars, teams
-- ---------------------------------------------------------------------------
-- Calendars are listed (not synced) so iMIP replies and task creation can offer
-- a target. Teams come from the Circles OCS API; a circle's `singleId` is a
-- string, hence the TEXT remoteId.

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
    -- v4 (ALTER TABLE, so rendered last): the default scheduling calendar; at most
    -- one per login by convention, not by constraint.
    isDefaultSchedule INTEGER NOT NULL DEFAULT 0,
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

-- ---------------------------------------------------------------------------
-- Snooze
-- ---------------------------------------------------------------------------
-- One row per snoozed message. The list excludes snoozed rows by anti-join; the
-- sweep that wakes them reads `until` through its index. INTEGER PRIMARY KEY is
-- a rowid alias, so the table is observable (ADR-0025).

CREATE TABLE snooze (
    messageId INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
    until     INTEGER NOT NULL
);

CREATE INDEX idxSnoozeUntil ON snooze(until);
