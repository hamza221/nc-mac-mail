// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The 412 path of ADR-0082, on the recorded lifecycle of one card edited by "another
/// client" (`dav-ws24-merge-*.xml`): the base, then a web edit of TEL, then of EMAIL.
@Suite("ContactWriteHandler: If-Match writes and the 412 reapply")
struct ContactWriteHandlerTests {
    private static let href = "/remote.php/dav/addressbooks/users/user/ws24-temp-merge/ws24-merge.vcf"
    private static let put: RequestMatcher = .method("PUT") && .pathSuffix("/ws24-merge.vcf")
    private static let multiget: RequestMatcher = .report && .bodyContains("addressbook-multiget")

    private struct Setup {
        let harness: ContactsHarness
        let handler: ContactWriteHandler
        let log: ContactConflictLog
        let bookId: Int64
        let base: ContactRecord
        let baseId: Int64

        /// The base card's row as it stands now.
        func row() async throws -> ContactRecord {
            try #require(try await harness.store.contact(id: baseId))
        }
    }

    /// A mirrored book holding the base card, and a handler over it.
    private func setUp() async throws -> Setup {
        let harness = try await ContactsHarness()
        let books = try await harness.store.syncAddressBooks(
            [
                AddressBookRecord(
                    loginId: harness.loginId,
                    url: "https://cloud.example.com/remote.php/dav/addressbooks/users/user/ws24-temp-merge/")
            ],
            loginId: harness.loginId)
        let bookId = try #require(books.first?.id)
        let (text, etag) = try await ContactsHarness.cardText(fixture: "dav-ws24-merge-base.xml")
        let row = try #require(
            ContactMapping.row(vcard: text, href: Self.href, etag: etag, addressBookId: bookId, syncedAt: 1))
        let base = try await harness.store.upsert(contact: row.record, emails: row.emails, phones: row.phones)
        let log = ContactConflictLog()
        let handler = ContactWriteHandler(store: harness.store, client: harness.client, conflicts: log)
        return Setup(
            harness: harness, handler: handler, log: log, bookId: bookId, base: base, baseId: try #require(base.id))
    }

    /// The user's offline edit of EMAIL, as the queue would carry it.
    private func emailEdit(_ setup: Setup, to address: String) throws -> DAVWrite {
        var card = try #require(try VCardParser.parse(setup.base.vcard).first)
        card.setProperty("EMAIL", to: address, parameters: [DirectoryParameter(name: "TYPE", values: ["WORK"])])
        let payload = ContactWriteHandler.putPayload(
            loginId: setup.harness.loginId, addressBookId: setup.bookId, existing: setup.base, card: card)
        #expect(payload.editedProperties == ["EMAIL"])
        return DAVWrite(operationId: 7, kind: .contactPut, accountId: 1, payload: payload)
    }

    private func sentBodies(_ transport: FakeTransport) async -> [String] {
        await transport.requests.filter { Self.put.matches($0) }
            .compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func applyShowsTheEditLocallyBeforeAnyRequest() async throws {
        let setup = try await setUp()
        let write = try emailEdit(setup, to: "merge-local@example.org")

        try await setup.handler.apply(write)

        let row = try await setup.row()
        #expect(row.vcard.contains("merge-local@example.org"))
        #expect(row.etag == setup.base.etag)
        #expect(await setup.harness.transport.sendCount == 0)
    }

    @Test func plainPutSendsIfMatchAndStoresTheNewETag() async throws {
        let setup = try await setUp()
        let write = try emailEdit(setup, to: "merge-local@example.org")
        try await setup.handler.apply(write)
        await setup.harness.transport.stub(
            Self.put, with: StubResponse(status: 204, body: Data(), headers: ["ETag": "\"new\""]))

        try await setup.handler.send(write)

        let request = try #require(await setup.harness.transport.requests.first { Self.put.matches($0) })
        #expect(request.value(forHTTPHeaderField: "If-Match") == setup.base.etag)
        let row = try await setup.row()
        #expect(row.etag == "\"new\"")
    }

    @Test func concurrentEditOfADifferentFieldMerges() async throws {
        let setup = try await setUp()
        let write = try emailEdit(setup, to: "merge-local@example.org")
        try await setup.handler.apply(write)
        await setup.harness.transport.stubSequence(
            Self.put, [.status(412), StubResponse(status: 204, body: Data(), headers: ["ETag": "\"merged\""])])
        await setup.harness.transport.stub(
            Self.multiget, with: try .fixture("dav-ws24-merge-server-tel.xml", status: 207))

        try await setup.handler.send(write)

        let bodies = await sentBodies(setup.harness.transport)
        #expect(bodies.count == 2)
        let merged = try #require(bodies.last)
        #expect(merged.contains("merge-local@example.org"))  // local EMAIL
        #expect(merged.contains("+1 555 0199"))  // the web's TEL
        #expect(!merged.contains("+1 555 0100"))
        let retry = try #require(await setup.harness.transport.requests.filter { Self.put.matches($0) }.last)
        let serverETag = try await ContactsHarness.cardText(fixture: "dav-ws24-merge-server-tel.xml").etag
        #expect(retry.value(forHTTPHeaderField: "If-Match") == serverETag)
        #expect(await setup.log.entries.isEmpty)

        let row = try await setup.row()
        #expect(row.vcard == merged)
        #expect(row.etag == "\"merged\"")
        let phones = try await setup.harness.store.contactPhones(contactId: setup.baseId)
        #expect(phones.map(\.number) == ["+1 555 0199"])
    }

    @Test func concurrentEditOfTheSameFieldKeepsLocalAndLogsTheConflict() async throws {
        let setup = try await setUp()
        let write = try emailEdit(setup, to: "merge-local@example.org")
        try await setup.handler.apply(write)
        await setup.harness.transport.stubSequence(
            Self.put, [.status(412), StubResponse(status: 204, body: Data(), headers: ["ETag": "\"merged\""])])
        await setup.harness.transport.stub(
            Self.multiget, with: try .fixture("dav-ws24-merge-server-email.xml", status: 207))

        try await setup.handler.send(write)

        let merged = try #require(await sentBodies(setup.harness.transport).last)
        #expect(merged.contains("merge-local@example.org"))
        #expect(!merged.contains("merge-web@example.org"))
        #expect(merged.contains("+1 555 0199"))  // the web's other change still lands
        let entries = await setup.log.entries
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .localWon(properties: ["EMAIL"]))
        #expect(entries.first?.operationId == 7)
    }

    @Test func aSecondPreconditionFailureGivesUpAsAConflictRow() async throws {
        let setup = try await setUp()
        let write = try emailEdit(setup, to: "merge-local@example.org")
        try await setup.handler.apply(write)
        await setup.harness.transport.stub(Self.put, with: .status(412))
        await setup.harness.transport.stub(
            Self.multiget, with: try .fixture("dav-ws24-merge-server-tel.xml", status: 207))

        await #expect(throws: DAVError.self) { try await setup.handler.send(write) }

        #expect(await sentBodies(setup.harness.transport).count == 2)  // retried exactly once
        #expect(await setup.log.entries.map(\.outcome) == [.gaveUp])
        // The local edit is still what the user sees, waiting for Retry or Discard.
        let row = try await setup.row()
        #expect(row.vcard.contains("merge-local@example.org"))
    }

    @Test func discardPutsTheBaseBack() async throws {
        let setup = try await setUp()
        let write = try emailEdit(setup, to: "merge-local@example.org")
        try await setup.handler.apply(write)

        await setup.handler.revert(write)

        let row = try await setup.row()
        #expect(row.vcard == setup.base.vcard)
        #expect(row.etag == setup.base.etag)
    }

    @Test func deleteAgainstANewerCopyStillDeletesAndLogs() async throws {
        let setup = try await setUp()
        let write = DAVWrite(
            operationId: 9, kind: .contactDelete, accountId: 1,
            payload: DAVWritePayload(
                loginId: setup.harness.loginId, addressBookId: setup.bookId, contactId: setup.base.id,
                href: Self.href, etag: setup.base.etag,
                before: DAVWriteSnapshot(existed: true, body: setup.base.vcard, etag: setup.base.etag)))
        try await setup.handler.apply(write)
        #expect(try await setup.harness.store.contact(id: setup.baseId) == nil)
        let delete: RequestMatcher = .method("DELETE") && .pathSuffix("/ws24-merge.vcf")
        await setup.harness.transport.stubSequence(delete, [.status(412), .status(204)])
        await setup.harness.transport.stub(
            Self.multiget, with: try .fixture("dav-ws24-merge-server-tel.xml", status: 207))

        try await setup.handler.send(write)

        let deletes = await setup.harness.transport.requests.filter { delete.matches($0) }
        #expect(deletes.count == 2)
        #expect(await setup.log.entries.map(\.outcome) == [.deletedNewer])
    }

    // MARK: - The merge rule itself

    @Test func editedPropertiesIgnoreBookkeepingLines() throws {
        let old = try #require(
            try VCardParser.parse("BEGIN:VCARD\r\nVERSION:3.0\r\nREV:1\r\nFN:A\r\nEND:VCARD\r\n").first)
        let new = try #require(
            try VCardParser.parse("BEGIN:VCARD\r\nVERSION:3.0\r\nREV:2\r\nFN:B\r\nNOTE:x\r\nEND:VCARD\r\n").first)
        #expect(ContactMerge.editedProperties(from: old, to: new) == ["FN", "NOTE"])
    }

    @Test func reapplyRemovesAPropertyTheUserDeleted() async throws {
        let base = try #require(
            try VCardParser.parse(try await ContactsHarness.cardText(fixture: "dav-ws24-merge-base.xml").text).first)
        let server = try #require(
            try VCardParser.parse(try await ContactsHarness.cardText(fixture: "dav-ws24-merge-server-tel.xml").text)
                .first)
        var local = base
        local.removeProperties("NOTE")
        let result = ContactMerge.reapply(local: local, onto: server, base: base, editedProperties: ["NOTE"])
        #expect(result.merged.property("NOTE") == nil)
        #expect(result.merged.property("TEL")?.rawValue == "+1 555 0199")
        #expect(result.conflicts.isEmpty)
    }
}
