<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Decision records

*Why the app is the way it is. One file per decision, numbered, never edited into
agreement — a decision that changes gets a new record that supersedes the old one, and the
old one stays.*

## Index

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-xcode-project-in-git.md) | Check an Xcode project into git rather than ship a pure SwiftPM app | Accepted |
| [0002](0002-app-password-login-flow-v2.md) | Authenticate with an app password obtained through Login Flow v2 | Accepted |
| [0003](0003-local-first-full-mirror.md) | Keep a complete local mirror and read from it always | Accepted — supersedes `plan/macos-client.md` "No local database" |
| [0004](0004-grdb-over-swiftdata.md) | GRDB.swift over SwiftData | Accepted |
| [0005](0005-offline-mutation-queue.md) | Queue mutations locally and replay them | Accepted |
| [0006](0006-data-at-rest.md) | Sandbox container plus FileVault, not an encrypted database | Accepted, with a named trigger to revisit |
| [0007](0007-subscribed-mailboxes-only.md) | Mirror subscribed mailboxes only | Accepted |
| [0008](0008-no-automatic-eviction.md) | No automatic eviction; the user manages storage | Accepted |
| [0009](0009-sanitised-html-not-raw-mime.md) | Store the server's sanitised HTML, not raw MIME | Accepted |
| [0010](0010-webview-scheme-handler.md) | Serve body images through a custom URL scheme | Accepted |
| [0011](0011-fts5-standalone-index.md) | FTS5 table holding its own copy of the text | Accepted |
| [0012](0012-read-and-triage-scope.md) | v1 is read and triage; no composer | Superseded by 0064 |
| [0013](0013-module-layout.md) | Four local packages plus one app target | Accepted |
| [0014](0014-singleton-enumeration.md) | Enumerate with `view=singleton`; thread locally | Accepted |
| [0015](0015-bounded-sync-window.md) | Bounded sync window plus periodic deep reconcile | Accepted |
| [0016](0016-warnings-as-errors-at-the-build-command.md) | Ask for warnings-as-errors at the build command, not in the manifests | Accepted |
| [0017](0017-file-system-synchronized-group.md) | The app target reads its sources from a synchronised folder | Accepted |
| [0018](0018-ad-hoc-signature-in-the-checked-in-project.md) | The checked-in project signs ad hoc | Accepted |
| [0019](0019-login-flow-verifies-the-mail-app.md) | `LoginFlow` proves the Mail app exists before reporting success | Accepted |
| [0020](0020-raw-json-in-a-wrapper.md) | Carry the server's JSON in a `RawBacked` wrapper, not in every model | Accepted |
| [0021](0021-one-message-flags-type.md) | One `MessageFlags` type for the envelope and the body | Accepted |
| [0022](0022-fixtures-by-path-not-bundle.md) | Tests read fixtures by path, not through `Bundle.module` | Superseded by ADR-0026 for `NCMailCoreTests`/`NCMailStoreTests`; still Accepted for `NCMailNetTests` |
| [0023](0023-store-records-are-not-wire-models.md) | Store records are their own types, and a write is narrower than a row | Accepted |
| [0024](0024-fts-deletes-in-a-trigger.md) | Delete the search index row from a trigger, not from Swift | Accepted |
| [0025](0025-rowid-tables-for-anything-observed.md) | Only unobserved tables may be `WITHOUT ROWID` | Accepted |
| [0026](0026-fixtures-through-a-dependency-free-target.md) | Fixtures through a dependency-free `NCMailFixtures` target | Accepted |
| [0027](0027-userdefaults-cache-for-the-launch-theme.md) | Cache the launch theme colour in `UserDefaults` for boot, `meta` for everything else | Accepted |
| [0028](0028-no-force-unwrap-even-in-tests.md) | No force unwrap anywhere, including tests — `#require` instead | Accepted |
| [0029](0029-app-test-target-borrows-its-modules-from-the-host.md) | The app's test target borrows its modules from the host app | Accepted; its workaround removed by ADR-0034 |
| [0030](0030-stage-one-owns-its-cursor.md) | Stage 1 owns its cursor — envelopes commit first, and priming never moves it | Accepted |
| [0031](0031-conditions-pushed-power-read.md) | The app pushes the network path into the mirror; the mirror reads the power state itself | Accepted |
| [0032](0032-body-text-is-not-kept-twice.md) | `messageBody.rawJSON` drops the `body` field | Accepted — narrows ADR-0020 |
| [0033](0033-accounts-have-a-local-identity.md) | Rows the server numbers get a local id and keep the server's as `remoteId` | Accepted |
| [0034](0034-the-store-returns-its-own-sequence.md) | `NCMailStore` returns its own `AsyncSequence`; no GRDB type crosses its boundary | Accepted |
| [0035](0035-sync-has-its-own-concurrency-limit.md) | The sync engine has its own concurrency limit and does not draw on the body budget | Accepted |
| [0036](0036-sort-order-decides-the-cursor.md) | The server-side sort order decides what a cursor means, and the tail scan needs newest-first | Accepted |
| [0037](0037-the-queue-is-read-twice-around-the-sync-write.md) | The operation queue is read twice around a sync write, until the store can read it inside one | Accepted, with a named replacement |
| [0038](0038-the-message-view-observes-the-thread.md) | The message view observes its thread, because the store cannot observe one body | Superseded by ADR-0045 |
| [0039](0039-a-rendered-message-holds-only-urls-we-would-fetch.md) | A rendered message holds only URLs we would fetch | Accepted |
| [0040](0040-list-view-is-remembered-per-app.md) | Threaded or flat is remembered once for the app, not once per account | Accepted |
| [0041](0041-unread-is-the-threads-unread-count.md) | A row is unread when its thread has unread messages, in both views | Accepted |
| [0042](0042-the-list-watches-one-mailbox-through-its-account.md) | The message list watches one mailbox through its account's mailbox observation | Superseded by ADR-0045 |
| [0043](0043-the-queue-names-the-storage-it-needs.md) | The mutation queue talks to a protocol, because `NCMailStore` has no queue DAO | Superseded by ADR-0045 |
| [0044](0044-the-queue-type-is-not-called-operationqueue.md) | The queue type is `MutationQueue`, not `OperationQueue` | Accepted |
| [0045](0045-the-store-grows-the-queue-dao-and-the-readers.md) | `NCMailStore` grows the queue DAO and the four readers the views worked around | Accepted — supersedes 0038, 0042, 0043 |
| [0046](0046-mailboxtree-takes-its-own-row-type.md) | `MailboxTree` takes its own row type, not `NCMailCore.Mailbox` | Accepted |
| [0047](0047-the-account-row-starts-the-engine.md) | The account row starts the engine, not the Keychain entry | Accepted |
| [0048](0048-one-footer-for-every-account.md) | The status footer adds every account's progress into one line | Accepted |
| [0049](0049-the-arrow-keys-stay-with-the-list.md) | `↑` and `↓` stay with the list; every other shortcut is a menu item | Accepted |
| [0050](0050-an-unavailable-action-says-why-in-the-menu.md) | An unavailable action says why in the menu, because a disabled button cannot | Accepted |
| [0051](0051-triage-owns-its-undo-manager.md) | Triage owns its `UndoManager`, and undo is the inverse operation | Accepted |
| [0052](0052-move-is-a-popover-because-a-menu-cannot-hold-a-field.md) | Move ▾ is a popover, because a menu cannot hold a filter field | Accepted |
| [0053](0053-settings-builds-its-own-short-lived-coordinators.md) | Settings builds its own short-lived sync objects rather than reaching into `AccountEngine` | Accepted |
| [0054](0054-the-passwords-are-read-off-the-main-thread.md) | Keychain attributes at launch, passwords off the main thread | Accepted |
| [0055](0055-the-search-field-cannot-reach-the-fts5-grammar.md) | The search field cannot reach the FTS5 grammar | Accepted |
| [0056](0056-search-results-are-flat-and-ranked.md) | Search results are a flat ranked list, whatever the list is set to | Accepted |
| [0057](0057-search-borrows-the-message-list.md) | Search borrows the message list instead of drawing its own | Accepted, with one thing still owed |
| [0058](0058-the-sidebar-opens-settings-through-userdefaults-and-a-selector.md) | The sidebar opens Settings through a `UserDefaults` key and an AppKit selector | Superseded by 0062 |
| [0059](0059-keychain-items-carry-a-security-domain.md) | Keychain items carry a security domain, and every query filters on it | Accepted |
| [0060](0060-unread-counts-come-from-the-mirror-once-complete.md) | A mailbox's unread count comes from the mirror once the mirror is complete | Accepted |
| [0061](0061-avatars-are-fetched-into-the-mirror-by-sync.md) | Avatars are fetched into the mirror by a sync worker, through the server's image route only | Accepted |
| [0062](0062-the-sidebar-opens-settings-with-opensettings.md) | The sidebar opens Settings with `openSettings`, and the tab is bound to its key | Accepted |
| [0063](0063-printing-uses-an-offscreen-web-view.md) | Printing builds its own offscreen web view, with the live view's configuration | Accepted |
| [0064](0064-v2-parity-scope.md) | v2 is parity with the Nextcloud Mail web client's user surfaces, plus Contacts | Accepted — supersedes 0012 |
| [0065](0065-native-rich-text-editor.md) | The composer is a TextKit 2 `NSTextView` this app owns, serialising to HTML itself | Accepted |
| [0066](0066-drafts-and-outbox.md) | Drafts are local rows synced to the server's draft API; sending goes through the server outbox | Accepted — send sequence refined by 0083 |
| [0067](0067-server-results-are-rows.md) | Server-computed results are cached rows | Accepted |
| [0068](0068-settings-commands.md) | Settings the server must validate are online-only commands | Accepted |
| [0069](0069-contacts-same-database.md) | Contacts use the same database and the same five modules, keyed by Nextcloud login | Accepted — 412 rule refined by 0082 |
| [0070](0070-contacts-sidebar-section.md) | Contacts appear as a sidebar section, under the mail accounts | Accepted |
| [0071](0071-widgets-read-snapshot.md) | Widgets read a snapshot file in the app group, never the database | Proposed |
| [0072](0072-local-first-autocomplete.md) | Recipient autocomplete is local-first | Proposed |
| [0073](0073-editor-canonical-html.md) | The editor serialises one canonical HTML form, and import makes any input canonical | Accepted |
| [0074](0074-editor-triggers.md) | Editor triggers are one session API; `:` opens the system emoji palette | Accepted |
| [0075](0075-lossless-raw-line-retention.md) | vCard and iCalendar properties keep their unfolded original line; untouched properties re-emit it | Accepted |
| [0076](0076-sync-truncation-is-a-flag.md) | A truncated sync-collection is a flag on a successful result, not an error | Accepted |
| [0077](0077-a-202-with-the-success-envelope-is-success.md) | A 202 carrying the success envelope is a success, not a sync in progress | Accepted |
| [0078](0078-flags-come-from-apis-or-default-on.md) | Server flags come from user-readable APIs or default to on; the web page is never scraped | Accepted |
| [0079](0079-a-login-table-roots-instance-state.md) | A `login` table is the local identity for instance-scoped state, and sign-out is two cascade roots | Accepted |
| [0080](0080-recorder-scratch-lifecycles-and-send-to-self.md) | The fixture recorder mutates only scratch objects, and sends only to the account itself | Accepted |
| [0081](0081-queued-rows-are-keyed-by-server-id.md) | Queued v2 settings rows are named by server id; offline creates get negative placeholders | Accepted |
| [0082](0082-contact-writes-reapply-per-property.md) | A contact write that meets a 412 reapplies the edited properties once; local wins a same-field race; a second 412 parks a conflict row | Accepted — refines 0069's 412 rule |
| [0083](0083-send-converts-the-server-draft-in-place.md) | A send converts the server draft in place, with `sendAt` pinned, and its state lives on the draft row | Accepted — refines 0066's send sequence |
| [0084](0084-the-shell-starts-logins-before-accounts.md) | The shell starts a login's engines before its accounts', stops them in reverse, and restores the local selection before the server's start mailbox | Accepted |

## Which ones matter most

**0003** is the spine. The mirror is why the product is worth building and why most of the
other decisions look the way they do. **0015** is the one most likely to be got wrong by
someone who reads the sync endpoint's parameter names and assumes they mean what they
say. **0006** is the one most likely to be challenged, and the record says what would
change our minds.

## Format

```markdown
# ADR-NNNN: Short imperative title

**Status:** Proposed | Accepted | Superseded by ADR-MMMM
**Date:** YYYY-MM-DD
**Decided by:** who, and on what evidence

## Context
The forces. What is true that makes this a question at all.

## Decision
What we are doing, in the present tense.

## Consequences
What this buys, what it costs, and what it forecloses. Costs are not optional to write.

## Alternatives considered
Each with the reason it lost. "We did not think of it" is a valid reason and should be
written down as one.

## Revisit when
The concrete trigger that would reopen this.
```

## Adding one

Any agent that makes a decision another agent could reasonably have made differently
writes a record. Cheap test: if you had to think for more than a minute, or if you can
imagine a reviewer asking "why not X", it is a decision.

Number sequentially, add a row above, and link it from whichever architecture document it
governs. Do not edit an existing record to match new reality — write the new one and mark
the old **Superseded by**.
