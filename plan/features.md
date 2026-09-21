# Nextcloud Mail feature list

Source: https://github.com/nextcloud/mail (main, app version 5.12.0-rc.1).
Server app written in PHP (Nextcloud 32 to 36, PHP 8.1 to 8.5) with a Vue 3 frontend.
IMAP/SMTP handling is built on the Horde libraries.

## Accounts and setup

- Multiple mail accounts per user, each with its own colour, order in the sidebar and settings.
- Account creation wizard with three modes: automatic discovery, manual server entry, and OAuth sign-in.
- Automatic configuration discovery: Mozilla ISPDB lookup (`autoConfig#queryIspdb`), MX record lookup (`autoConfig#queryMx`), and a connectivity test endpoint (`autoConfig#testConnectivity`).
- Manual IMAP settings: host, port, security (None, STARTTLS, SSL/TLS, Auto), user, password.
- Manual SMTP settings: host, port, security, user, password.
- Credentials are synced between the IMAP and SMTP fields while filling in the form.
- Google (Gmail) OAuth sign-in, configured by the admin with a client id and secret. Refresh tokens are stored and refreshed automatically (`OauthTokenRefreshListener`).
- Microsoft (Outlook) OAuth sign-in with a configurable tenant id, client id and secret.
- OAuth state token endpoint (`oauth#generateState`) and a popup flow (`main-oauth-popup.js`, `OauthDone.vue`).
- Reconnect flow for expired Google or Microsoft consent.
- Account connection test endpoint (`accounts#testAccountConnection`) and a "this account cannot connect" state in the sidebar.
- Change-password shortcut in the account server settings.
- Use the Nextcloud login password as the mail password (`password-is-unavailable` state handles SSO sessions where it is not available).
- Per-account debug flag that raises log verbosity.
- Experimental JMAP protocol support: `protocol` column on the account (`imap`/`jmap`), `JmapClientFactory`, `JmapClientAdapter`, `ProtocolFactory`, and `occ` commands to create and update JMAP accounts. The connector map in `ProtocolFactory` is still commented out, so this is groundwork rather than a finished path.

## Mailboxes and folders

- Folder list per account with subscription state, unread counts and background-sync toggle.
- Special folder detection and assignment: Inbox, Drafts, Sent, Trash, Archive, Junk, Snoozed (`MailboxesSynchronizedSpecialMailboxesUpdater`).
- Create folder and create subfolder.
- Rename folder, move folder, delete folder.
- Clear folder (delete all messages in it).
- Mark all messages in a folder as read.
- Subscribe and unsubscribe from folders, plus a "show subscribed only" account setting.
- Per-folder background sync toggle.
- Clear the local cache for a folder and repair a folder (rate limited to one repair per 10 minutes).
- Folder statistics endpoint (`mailboxes#stats`) and quota reporting per account (`accounts#getQuota`), with a quota-depleted notification.
- Unified inbox across all accounts.
- Filter folders by name in the folder picker.
- Personal namespace handling for servers that use one.

## Message list

- Threaded and non-threaded list layouts, chosen per user with an admin-set default (`layout_message_view`).
- Three layout modes: vertical split, horizontal split, and list.
- Compact mode.
- Sort newest first or oldest first.
- Option to sort favourites to the top.
- Infinite scroll (`src/directives/infinite-scroll.js`) with loading skeletons.
- Date grouping in the list (Today, Yesterday, Last week, Last month, Last hour).
- Envelope preview text and, when enabled, an AI-generated summary line.
- Avatars in the list from address book photos, Gravatar and site favicons.
- Drag and drop of messages onto folders (`src/directives/drag-and-drop`).
- Single-click actions on an envelope and a primary-action row.
- Selection and bulk actions over multiple messages.
- Snoozed message indicator and follow-up indicator.

## Priority inbox

- Splits the inbox into Important and Other sections, plus Favorites and Follow up sections.
- On-device importance classification trained per account (`ImportanceClassifier`, Rubix ML), with a rules-based fallback classifier.
- Feature extractors: sender in important messages, read messages, replied messages, sent messages, and subject.
- Training runs as a background job (`TrainImportanceClassifierJob`) and can be triggered by `occ mail:train-account`.
- Prediction available through `occ mail:predict-importance` and a meta estimator runner (`occ`, `RunMetaEstimator`).
- Per-account toggle for the classification, plus an admin default (`importance_classification_default`).
- Option to include the message body when searching in the priority inbox.

## Reading messages

- Plain text and HTML rendering, with HTML sanitised through HTMLPurifier and displayed in a sandboxed iframe.
- Blocked remote content by default with a warning bar and a per-sender "always show images from" allow list (trusted senders).
- Image proxy endpoint (`proxy#proxy`) so remote images do not leak the user's IP.
- Attachment list with download of a single attachment or all attachments as a zip.
- Save an attachment to Files, and save the whole message to Files as an `.eml` file.
- Print a message (Cmd/Ctrl+P inside the message frame, `src/util/printMessage.ts`).
- View the raw message source (`messages#getSource`) and export the message (`messages#export`).
- Copy a direct link to a message (`DeepLinkController`, `/open/{messageId}`).
- Thread view with expand and collapse per message, and an option to show only the selected message.
- Mark as read automatically after a configurable delay, or only manually.
- Message disposition notifications: request a read receipt when composing, and reply to an MDN request when reading (`messages#mdn`).
- DKIM signature check per message (`messages#getDkim`, `DkimService`).
- Mailing list unsubscribe, both the `List-Unsubscribe` URL and the email variant (`list#unsubscribe`).
- Mentions detection (`mentionsMe` flag) and a "To me" search filter.
- Language detection in the browser for the translation feature.

## Composing and sending

- Rich text editor based on CKEditor 5 with custom plugins: signature insertion, quote handling, text direction, Nextcloud smart picker, and images from Files.
- Plain text editor mode, with a per-account preferred writing mode.
- Floating composer with minimise, maximise and restore.
- Reply, reply all, reply to sender only, forward, and edit as new message.
- Reply position setting (quote above or below).
- Recipient fields with autocomplete over Nextcloud contacts, collected addresses, Nextcloud users and groups.
- Cc and Bcc fields, recipient bubbles with contact details on click.
- Attachments by upload, by drag and drop, by paste, or picked from Files.
- Attach a Files item either as a real attachment or as a share link.
- Insert images from Files inline in the body.
- Text blocks: reusable snippets, insertable from the composer, shareable with users and groups.
- Signatures per account and per alias, HTML or plain text, placed above or below the quote.
- Draft autosave with a status indicator, manual save with Ctrl+S, and a background job that flushes drafts to IMAP (`DraftsJob`).
- Discard draft.
- Outbox with scheduled send ("send later", with Tomorrow morning, Tomorrow afternoon, Monday morning and a custom date and time), processed by `OutboxWorkerJob`.
- Send now, and convert an existing draft into an outbox message.
- Warnings before sending: empty subject, mention of an attachment with none attached, empty recipients, and replying to a `noreply@` address.
- Mark a message as AI generated.
- Anti-abuse checks before sending (`AntiAbuseHandler`), with a send handler chain that also files the sent copy and flags the replied-to message.
- Copy of the sent message written to the configured Sent folder.
- `mailto:` handler route and a "set as default mail app" button.

## Encryption and signing

- S/MIME: import certificates (PKCS#12), map aliases to certificates, sign, encrypt, decrypt and verify messages, with signature-verified and unverified badges.
- Certificate management UI with purposes and expiry information.
- Mailvelope integration for OpenPGP: detection of the extension, an editor for encrypted composing, and decryption of received messages.
- Warning when a recipient has no PGP key or no S/MIME certificate.

## Organising messages

- Flags: read/unread, favourite (starred), important, answered, forwarded, junk, draft, deleted, attachments, MDN sent.
- Tags (IMAP keywords) with a colour, create, rename, delete, and per-message assignment. Default tags are added on install and repaired by a migration.
- Move message or whole thread to another folder, with a folder picker.
- Archive message or thread.
- Delete message or thread, with trash-folder awareness.
- Mark as spam and mark as not spam, including moving to the Junk folder and reporting.
- Snooze and unsnooze a message or a thread until a chosen time, with a dedicated Snoozed folder and a `WakeJob` that moves messages back.
- Automatic trash deletion after a configurable number of days per account (`TrashRetentionJob`).
- Quick actions: user-defined named action chains per account, built from steps `markAsSpam`, `applyTag`, `snooze`, `moveThread`, `deleteThread`, `markAsRead`, `markAsUnread`, `markAsImportant`, `markAsFavorite`.
- Follow-up reminders: messages you sent that received no reply are detected (`FollowUpClassifierJob`, optionally LLM-assisted) and shown in a Follow up section, with a per-user toggle.

## Search

- In-app search modal with fields for sender, recipients, Cc, Bcc, subject, body, tags, date range, attachments, flags and "mentions me".
- Search filter string syntax parsed server side: `from:`, `to:`, `cc:`, `bcc:`, `subject:`, `body:`, `tags:`, `start:`, `end:`, `match:`, `mentions:`, `flags:`, `is:`/`not:` with `answered`, `read`, `unread`, `starred`, `important`, `pi-important`, `pi-other`.
- Search scoped to a folder or across the account.
- Body search toggle per account (server-side IMAP body search can be slow).
- Nextcloud unified search provider, plus a filtering provider that accepts search filters.

## Filters and automation

- Sieve support: enable a Sieve server per account (host, port, security, user, password) and edit the active script directly.
- Visual mail filter builder that generates Sieve: conditions on From, Subject and To with `contains`, `is` and `matches`, combined with all-of or any-of, and actions to add a flag, add a system flag (`\Answered`, `\Deleted`, `\Draft`, `\Flagged`, `\Seen`), file into a folder, redirect to an address, or stop.
- Filter priority ordering and enable/disable per filter.
- Create a filter directly from a message ("filter from envelope").
- Out of office autoresponder written into the Sieve script, with a start and end date, subject and message.
- Option to follow the Nextcloud system absence setting, kept in sync by a listener and the `occ mail:update-system-autoresponders` command.
- Antispam reporting: admin-configured spam and ham addresses receive forwarded reports when a user marks a message.

## AI and assistance features

All of these run through the Nextcloud Task Processing API and are off unless the admin enables LLM processing.

- Thread summaries (`thread#summarize`) and per-message summaries generated on arrival (`NewMessagesSummarizeListener`).
- Smart replies: two short suggested replies per message (`messages#smartReply`).
- Event data generation from a thread, producing a title and agenda for a calendar event (`thread#generateEventData`).
- Follow-up detection asking whether a sent message expects a reply.
- Message translation with language pickers driven by the available task-processing languages.
- Context Chat integration: opt-in indexing of mail content so the Context Chat app can answer questions about it (`SubmitContentJob`, per-user and admin defaults).
- Prompts live in `DefaultPrompts` and include explicit instructions to treat message content as untrusted and ignore embedded instructions.

## Integration with other Nextcloud apps

- Contacts: autocomplete, contact details popover, add an address to an existing contact, create a new contact, and automatic collection of addresses you write to (`AddressCollector`, with a privacy toggle).
- Calendar: import iMIP invitations, respond to invitations, create an event from a thread, calendar picker in account settings, and an `IMipMessageJob` that processes invitations in the background.
- Tasks: create a task from a message.
- Files: attach from Files, save attachments to Files, save the message as `.eml`, insert images from Files, and share attachments as links.
- Dashboard widgets: unread mail and important mail.
- Notifications: new message notifications, quota depleted, and account delegation.
- Unified search provider.
- Talk-style smart picker support in the editor.
- Mail provider API for other apps (`OCA\Mail\Provider\MailProvider`, `MailService`, `MessageSend` command) so other apps can list mail services and send messages.
- User data migration: export and import mail accounts through the Nextcloud user migration framework.
- Viewer app integration for attachments.
- Webhook-compatible events for new messages, sent messages, flag changes, deletions and drafts.

## Itinerary extraction

- KItinerary integration (`ItineraryExtractor`) that parses booking confirmations.
- Rendered cards for flight reservations, train reservations and event reservations, with a one-click calendar import.
- Extraction results are cached per message (`messages#getItineraries`).

## Security features

- Phishing detection with several checks: sender address mismatch with contacts, custom email display-name spoofing, date anomalies, IMAP junk flag, link text versus link target mismatch, and Reply-To mismatch. Results are shown as a warning banner.
- Internal address and domain list so recognised internal senders are not flagged, with a "highlight external addresses" toggle.
- Trusted senders list controlling remote image loading.
- DKIM validation per message.
- HTML sanitisation and a strict content security policy for message bodies.
- Rate limiting on IMAP authentication rejections.
- Setup checks shown to admins: mail transport, IMAP connection performance, and microtime precision.

## Delegation and sharing

- Account delegation: grant another Nextcloud user access to your mail account, with per-request access assertions on accounts, mailboxes, messages, aliases and local messages, and an audit log entry for delegated actions.
- Delegated accounts appear in the recipient's sidebar marked as delegated.
- Text block sharing with individual users and with groups.

## Aliases

- Multiple aliases per account with their own name, signature, and S/MIME certificate mapping.
- Alias provisioning from LDAP attributes.

## Administration

- Admin settings page under Groupware with provisioning, antispam, OAuth and AI sections.
- Provisioning: rules matched by domain that create and update mail accounts automatically from the user's Nextcloud account, with templated email, IMAP, SMTP and Sieve settings, a master password or master user, and LDAP-driven aliases. Includes a preview of what a rule would provision, and provision/deprovision actions.
- Toggle whether users may add their own mail accounts.
- Default message list layout for users who have not chosen one.
- Default for importance classification and for Context Chat indexing.
- Google and Microsoft OAuth client configuration, with the secrets stored encrypted.
- Enable or disable LLM processing, with indicators for which task-processing backends are available.
- Config keys are declared in `ConfigLexicon` so `occ config:app:*` describes them.

## Background jobs

`CleanupJob`, `SyncJob`, `RepairSyncJob`, `OutboxWorkerJob`, `DraftsJob`, `IMipMessageJob`, `TrashRetentionJob`, `WakeJob` (snooze), `QuotaJob`, `TrainImportanceClassifierJob`, `FollowUpClassifierJob`, `PreviewEnhancementProcessingJob`, `MigrateImportantJob`, `DeleteDuplicatedUidsJob`, and the Context Chat `SubmitContentJob`.

Scheduled send and snooze are hidden in the UI when the server uses ajax cron, since that is too unreliable for them.

## Command line (occ)

`mail:account:create`, `mail:account:create-jmap`, `mail:account:update`, `mail:account:update-jmap`, `mail:account:delete`, `mail:account:export`, `mail:account:export-threads`, `mail:account:test`, `mail:account:debug`, `mail:account:sync`, `mail:account:train`, `mail:mailbox:list`, `mail:mailbox:inspect`, `mail:mailbox:unlock`, `mail:mailbox:clear-cache`, `mail:tags:add-missing`, `mail:tags:create-migration-job`, `mail:cleanup`, `mail:predict-importance`, `mail:thread`, `mail:update-system-autoresponders`, and `mail:run-meta-estimator`.

## Synchronisation and caching

- Incremental IMAP sync using QRESYNC/CONDSTORE where available, with a local database cache of messages (`ImapToDbSynchronizer`, `SyncService`).
- Horde cache backed by the Nextcloud cache (`HordeCacheFactory`), with sync token parsing.
- Threading built locally from `Message-ID`, `References` and `In-Reply-To` (`ThreadBuilder`), with a repair step.
- Preview text enhancement as a separate background pass.
- Structure analysis flags (has attachments, encrypted, iMIP) stored per message.
- Optional database indices added lazily (`OptionalIndicesListener`).
- Duplicate UID cleanup migration and job.

## Public API

- OCS endpoints: `GET /message/{id}`, `GET /message/{id}/raw`, `GET /message/{id}/attachment/{attachmentId}`.
- App-level REST API under `/apps/mail/api/` covering accounts, aliases, mailboxes, messages, threads, drafts, outbox, attachments, tags, preferences, S/MIME certificates, text blocks, quick actions, trusted senders, internal addresses, Sieve, out of office, delegations and follow-up checks.

## Accessibility and localisation

- Translated through Transifex into the full Nextcloud language set (`l10n/`).
- Keyboard shortcuts: `C` compose, `ArrowLeft`/`ArrowRight` newer/older message, `S` toggle star, `U` toggle unread, `A` archive, `Delete` delete, `Ctrl+F` search, `Ctrl+Enter` send, `R` refresh, `Ctrl+Alt+1/2/3` headings in the editor, `Ctrl+S` save draft, `Ctrl/Cmd+P` print.
- Dark mode and theming follow the Nextcloud server theme.

## Developer tooling in the repo

- PHPUnit unit and integration suites, Vitest frontend unit tests, and a Playwright end-to-end test.
- Psalm static analysis with a baseline, ESLint, Stylelint, Rector, and REUSE licence compliance.
- Webpack builds for dev, prod and test, and a Makefile with `make dev-setup`.
- Renovate for dependency updates and a patch system (`patches/`, `patches.json`).
