// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// WS-36, found live: a rename and an on/off toggle of one book, queued before a drain, fold
/// into one `addressBookUpdate`. The fold has to carry both fields, or the PROPPATCH sends the
/// toggle alone and the server keeps the old name.
@Suite("Address book update folding")
struct AddressBookUpdateFoldTests {
    private static let bookPath = "/remote.php/dav/addressbooks/users/user/contacts/"

    private func drainedBodies(_ operations: (Int64) -> [MailOperation]) async throws -> [String] {
        let harness = try await ContactsHarness()
        let identity = ServerIdentity(serverURL: "https://cloud.example.com", loginName: "user")
        let accounts = try await harness.store.upsert(accounts: [
            AccountWrite(
                identity: identity, remoteId: 1, name: "User", emailAddress: "user@example.invalid", rawJSON: "{}")
        ])
        let accountId = try #require(accounts.first?.id)
        _ = try await harness.store.syncAddressBooks(
            [AddressBookRecord(loginId: harness.loginId, url: ContactsHarness.contactsBook, displayName: "Contacts")],
            loginId: harness.loginId)
        let configuration = MutationQueueConfiguration(
            dav: ContactWriteHandler(store: harness.store, client: harness.client))
        let queue = MutationQueue(store: harness.store, configuration: configuration)
        for operation in operations(harness.loginId) {
            try await queue.perform(operation, loginId: harness.loginId)
        }
        await harness.transport.stub(.proppatch, with: try .fixture("dav-proppatch.xml", status: 207))
        let client = MailClient(
            server: try #require(URL(string: "https://cloud.example.com")),
            credentials: BasicCredentials(loginName: "user", appPassword: "secret"),
            transport: harness.transport, retryPolicy: .none, clientVersion: "test")
        await OperationDrainer(store: harness.store, client: client, accountId: accountId, configuration: configuration)
            .drain()
        #expect(try await queue.pendingDAVWrites(loginId: harness.loginId).isEmpty)
        return await harness.transport.requests.filter { $0.httpMethod == "PROPPATCH" }
            .map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    }

    private func update(_ loginId: Int64, name: String? = nil, enabled: Bool? = nil) -> MailOperation {
        .addressBookUpdate(
            DAVWritePayload(
                loginId: loginId, href: Self.bookPath, displayName: name, enabled: enabled,
                before: DAVWriteSnapshot(displayName: "Contacts")))
    }

    @Test func renameThenDisableDrainsOnePropPatchCarryingBoth() async throws {
        let bodies = try await drainedBodies { [update($0, name: "Renamed"), update($0, enabled: false)] }
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        #expect(body.contains("Renamed"))
        #expect(body.contains("enabled>0<"))
    }

    @Test func disableThenRenameDrainsOnePropPatchCarryingBoth() async throws {
        let bodies = try await drainedBodies { [update($0, enabled: false), update($0, name: "Renamed")] }
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        #expect(body.contains("Renamed"))
        #expect(body.contains("enabled>0<"))
    }

    @Test func laterValuesWinFieldByField() {
        let first = DAVWritePayload(loginId: 1, displayName: "A", color: "#111111", enabled: true)
        let later = DAVWritePayload(loginId: 1, displayName: "B")
        let merged = first.merging(later)
        #expect(merged.displayName == "B")
        #expect(merged.enabled == true)
        #expect(merged.color == "#111111")
    }
}
