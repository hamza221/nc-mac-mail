// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// ADR-0093: a `calendarPut` whose UID the calendar already holds (the copy scheduling
/// delivered) is written once more onto that copy, on the recorded 409 body.
@Suite("ContactWriteHandler: calendarPut onto the server's copy of a UID")
struct CalendarPutTests {
    private static let ours = "/remote.php/dav/calendars/user/personal/ws34-second.ics"
    private static let theirs = "/remote.php/dav/calendars/user/personal/ws34-first.ics"
    private static let body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"

    private func write(etag: String? = nil) throws -> DAVWrite {
        DAVWrite(
            operationId: 3,
            kind: .calendarPut,
            accountId: 1,
            payload: DAVWritePayload(loginId: 1, calendarId: 1, href: Self.ours, body: Self.body, etag: etag)
        )
    }

    @Test("409 no-uid-conflict: the same body goes to the server's href, with no If-Match")
    func uidConflictRetargetsOnce() async throws {
        let harness = try await ContactsHarness()
        let woken = WakeCounter()
        let handler = ContactWriteHandler(
            store: harness.store, client: harness.client, afterSend: { _ in await woken.bump() })
        await harness.transport.stub(
            .method("PUT") && .pathSuffix("/ws34-second.ics"),
            with: try .fixture("dav-error-uid-conflict-ws34.xml", status: 409))
        await harness.transport.stub(
            .method("PUT") && .pathSuffix("/ws34-first.ics"),
            with: StubResponse(status: 204, body: Data(), headers: ["ETag": "\"new\""]))

        try await handler.send(try write(etag: "\"stale-or-nil\""))

        let puts = await harness.transport.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 2)
        let retry = try #require(puts.last)
        #expect(retry.url?.path() == Self.theirs)
        #expect(retry.value(forHTTPHeaderField: "If-Match") == nil)
        #expect(retry.httpBody.map { String(decoding: $0, as: UTF8.self) } == Self.body)
        #expect(await woken.count == 1)
    }

    @Test("a second 409 throws, and the drainer parks it as a conflict")
    func secondConflictParks() async throws {
        let harness = try await ContactsHarness()
        let handler = ContactWriteHandler(store: harness.store, client: harness.client)
        await harness.transport.stub(
            .method("PUT"), with: try .fixture("dav-error-uid-conflict-ws34.xml", status: 409))

        do {
            try await handler.send(try write())
            Issue.record("expected the second 409 to throw")
        } catch let error as DAVError {
            guard case .uidConflict = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(OperationDrainer.mailError(for: error) is DAVConflict)
        }
        #expect(await harness.transport.requests.filter { $0.httpMethod == "PUT" }.count == 2)
    }
}

private actor WakeCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
