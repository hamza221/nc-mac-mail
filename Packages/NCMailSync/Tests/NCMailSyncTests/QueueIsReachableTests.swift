// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import NCMailTestSupport
import Testing

/// **No `@testable` anywhere in this file, and that is the assertion.**
///
/// The queue could not be wired into the app at all while its storage was a protocol whose
/// only conformance lived in this test target: nothing outside `NCMailSync` could produce
/// an `OperationStoring`, so `MutationQueue` had no reachable initialiser and WS-10 and
/// WS-12 were blocked on it
/// ([ADR-0045](../../../../../docs/decisions/0045-the-store-grows-the-queue-dao-and-the-readers.md)).
/// A plain `import` sees only what a view or an app-shell would see, so if this file
/// compiles, the block is gone.
@Suite("The queue is reachable from outside NCMailSync")
struct QueueIsReachableTests {
    @Test("a queue and a drainer are built from a MailStore and nothing else")
    func theAppCanBuildTheQueue() async throws {
        let store = try MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: 2, threadSize: 1)
        let client = MailClient(
            server: try #require(URL(string: "https://cloud.example.invalid")),
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: FakeTransport()
        )

        let drainer = OperationDrainer(store: store, client: client, accountId: seed.accountId)
        let queue = MutationQueue(store: store, drainer: drainer)

        // And it does the one thing it is for, through the public API only.
        try await queue.perform(
            .setFlags(messageIds: [seed.messageIds[0]], flags: ["seen": true]),
            accountId: seed.accountId
        )
        #expect(try await store.message(id: seed.messageIds[0])?.isSeen == true)
        #expect(try await store.pendingOperations(accountId: seed.accountId).count == 1)
    }
}
