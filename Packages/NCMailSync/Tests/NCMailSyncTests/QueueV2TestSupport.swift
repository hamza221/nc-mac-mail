// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The v1 queue fixture plus what the v2 kinds name: a snooze mailbox, a login, tags,
/// aliases, text blocks and quick actions with known server ids, and a DAV handler that
/// records what it was asked to do.
///
/// Seeded server ids are chosen to differ from the ids the recorded create fixtures answer
/// with (tag 13, mailbox 19, alias 11, text block 8, quick action 10, step 14), so a test can
/// tell a seeded row from one a create produced.
enum QueueV2Test {
    struct Fixture {
        var base: QueueTest.Fixture
        var queue: MutationQueue
        var drainer: OperationDrainer
        var dav: RecordingDAVHandler
        var configuration: MutationQueueConfiguration
        var loginId: Int64
        var snoozeId: Int64
        var oldMailboxId: Int64

        var store: MailStore { base.store }
        var accountId: Int64 { base.accountId }
        var transport: FakeTransport { base.transport }

        func rows() async throws -> [PendingOperationRecord] {
            try await base.store.pendingOperations(accountId: base.accountId)
        }

        /// A drainer over `store`, as a relaunched app would build one.
        func drainer(store: MailStore, transport: FakeTransport) throws -> OperationDrainer {
            OperationDrainer(
                store: store,
                client: try MirrorTest.client(transport),
                accountId: accountId,
                configuration: configuration
            )
        }
    }

    static let remoteSnooze: Int64 = 923
    static let remoteOld: Int64 = 924
    static let tagUpdated: Int64 = 5
    static let tagDeleted: Int64 = 6
    static let aliasUpdated: Int64 = 31
    static let aliasDeleted: Int64 = 32
    static let blockUpdated: Int64 = 41
    static let blockDeleted: Int64 = 42
    static let actionUpdated: Int64 = 51
    static let actionDeleted: Int64 = 52
    static let stepUpdated: Int64 = 61
    static let stepDeleted: Int64 = 62

    static func make(url: URL? = nil, dav: RecordingDAVHandler = RecordingDAVHandler()) async throws -> Fixture {
        let base = try await QueueTest.make(url: url)
        let store = base.store
        let folders = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: base.accountId, remoteId: remoteSnooze, name: "Snoozed", delimiter: "/",
                    displayName: "Snoozed", isSubscribed: true),
                MailboxWrite(
                    accountId: base.accountId, remoteId: remoteOld, name: "Old", delimiter: "/", displayName: "Old",
                    isSubscribed: true),
            ],
            accountId: base.accountId
        )
        var account = AccountWrite(record: try #require(try await store.account(id: base.accountId)))
        account.snoozeMailboxId = remoteSnooze
        try await store.upsert(accounts: [account])
        let login = try await store.ensureLogin(MailStoreFixtures.identity)
        let loginId = try #require(login.id)
        let accountId = base.accountId

        // Seeded through the store's own row effects, which is also how the queue writes them.
        try await store.finish(
            ids: [],
            applying: [
                LocalEffect(
                    messageIds: [],
                    rows: [
                        .upsertTag(
                            accountId: accountId, remoteId: tagUpdated, imapLabel: "$label1", displayName: "Work",
                            color: "#ff0000"),
                        .upsertTag(
                            accountId: accountId, remoteId: tagDeleted, imapLabel: "$label2", displayName: "Home",
                            color: "#00ff00"),
                        .upsertAlias(
                            AliasRecord(
                                accountId: accountId, remoteId: aliasUpdated, email: "a@example.invalid", name: "A",
                                smimeCertificateRemoteId: 7)),
                        .upsertAlias(
                            AliasRecord(
                                accountId: accountId, remoteId: aliasDeleted, email: "b@example.invalid", name: "B")),
                        .upsertTextBlock(
                            TextBlockRecord(loginId: loginId, remoteId: blockUpdated, title: "Hi", content: "Hello")),
                        .upsertTextBlock(
                            TextBlockRecord(loginId: loginId, remoteId: blockDeleted, title: "Bye", content: "Bye")),
                        .setTextBlockShare(
                            loginId: loginId, textBlockRemoteId: blockUpdated, shareWith: "carol", type: "user",
                            displayName: "Carol", present: true),
                        .upsertQuickAction(
                            QuickActionRecord(accountId: accountId, remoteId: actionUpdated, name: "Triage")),
                        .upsertQuickAction(
                            QuickActionRecord(accountId: accountId, remoteId: actionDeleted, name: "Old")),
                        .upsertQuickActionStep(
                            accountId: accountId, quickActionRemoteId: actionUpdated,
                            step: QuickActionStepRecord(
                                quickActionId: 0, remoteId: stepUpdated, name: "markAsRead", position: 1)
                        ),
                        .upsertQuickActionStep(
                            accountId: accountId, quickActionRemoteId: actionUpdated,
                            step: QuickActionStepRecord(
                                quickActionId: 0, remoteId: stepDeleted, name: "markAsSpam", position: 2)
                        ),
                    ]
                )
            ]
        )

        let clock = base.clock
        let configuration = MutationQueueConfiguration(
            backoffSeconds: [2, 8, 30, 120, 600],
            now: { clock.now },
            dav: dav
        )
        let drainer = OperationDrainer(
            store: store,
            client: try MirrorTest.client(base.transport),
            accountId: accountId,
            configuration: configuration
        )
        return Fixture(
            base: base,
            queue: MutationQueue(store: store, drainer: nil, configuration: configuration),
            drainer: drainer,
            dav: dav,
            configuration: configuration,
            loginId: loginId,
            snoozeId: try #require(folders.first { $0.remoteId == remoteSnooze }).id,
            oldMailboxId: try #require(folders.first { $0.remoteId == remoteOld }).id
        )
    }

    static func davPayload(
        _ loginId: Int64, href: String, body: String? = nil, edited: [String] = []
    ) -> DAVWritePayload {
        DAVWritePayload(
            loginId: loginId,
            collectionHref: "/remote.php/dav/addressbooks/users/alice/contacts/",
            href: href,
            body: body,
            etag: "\"1\"",
            editedProperties: edited,
            displayName: "Contacts",
            sharee: "principal:principals/users/bob",
            before: DAVWriteSnapshot(existed: true, body: "BEGIN:VCARD\r\nEND:VCARD\r\n", etag: "\"1\"")
        )
    }

    // MARK: - Server answers

    /// Every v2 route, answered as the live server answered when the fixtures were recorded.
    /// Specific matchers first: the fake answers with the first that matches.
    static func stubV2(_ transport: FakeTransport) async throws {
        func route(_ method: String, _ test: @escaping @Sendable (String) -> Bool) -> RequestMatcher {
            RequestMatcher.method(method) && RequestMatcher("\(method) path") { test($0.url?.path ?? "") }
        }
        let stubs: [(RequestMatcher, StubResponse)] = [
            (
                route("PUT") { $0.contains("/messages/") && $0.contains("/tags/") },
                try .fixture("message-tag-added.json")
            ),
            (
                route("DELETE") { $0.contains("/messages/") && $0.contains("/tags/") },
                try .fixture("message-tag-removed.json")
            ),
            (route("POST") { $0.hasSuffix("/api/tags") }, try .fixture("tag-created.json")),
            (route("PUT") { $0.contains("/api/tags/") }, try .fixture("tag-updated.json")),
            (route("POST") { $0.hasSuffix("/api/mailboxes") }, try .fixture("mailbox-created.json")),
            (route("PATCH") { $0.contains("/api/mailboxes/") }, try .fixture("mailbox-patched.json")),
            (route("PUT") { $0.contains("/api/preferences/") }, try .fixture("preference-saved.json")),
            (route("PATCH") { $0.contains("/api/accounts/") }, try .fixture("account-patch.json")),
            (route("POST") { $0.hasSuffix("/aliases") }, try .fixture("alias-created.json")),
            (
                route("PUT") { $0.contains("/aliases/") && !$0.hasSuffix("/signature") },
                try .fixture("alias-updated.json")
            ),
            (route("DELETE") { $0.contains("/aliases/") }, try .fixture("alias-deleted.json")),
            (route("POST") { $0.hasSuffix("/api/textBlocks") }, try .fixture("text-block-created.json")),
            (route("PUT") { $0.contains("/api/textBlocks/") }, try .fixture("text-block-updated.json")),
            (route("POST") { $0.hasSuffix("/api/quick-actions") }, try .fixture("quick-action-created.json")),
            (route("PUT") { $0.contains("/api/quick-actions/") }, try .fixture("quick-action-updated.json")),
            (route("POST") { $0.hasSuffix("/api/action-step") }, try .fixture("action-step-created.json")),
            (route("PUT") { $0.contains("/api/action-step/") }, try .fixture("action-step-updated.json")),
            // Everything else — deletes, snoozes, clear/read, signatures, shares, internal
            // addresses, trusted domains, mdn, unsubscribe, files — answers an empty 200.
            (.any, .status(200)),
        ]
        for (matcher, response) in stubs {
            await transport.stub(matcher, with: response)
        }
    }
}

/// A `DAVWriteHandling` that does no DAV and remembers every call.
actor RecordingDAVHandler: DAVWriteHandling {
    private(set) var applied: [OperationKind] = []
    private(set) var sent: [DAVWrite] = []
    private(set) var reverted: [OperationKind] = []
    /// Errors thrown by the next `send` calls, in order.
    private var failures: [any Error] = []

    func failNextSends(with errors: [any Error]) {
        failures = errors
    }

    func apply(_ write: DAVWrite) async throws {
        applied.append(write.kind)
    }

    func send(_ write: DAVWrite) async throws {
        if !failures.isEmpty { throw failures.removeFirst() }
        sent.append(write)
    }

    func revert(_ write: DAVWrite) async {
        reverted.append(write.kind)
    }
}
