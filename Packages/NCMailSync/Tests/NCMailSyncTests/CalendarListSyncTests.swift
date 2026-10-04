// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

@Suite("CalendarListSync against the recorded calendar home")
struct CalendarListSyncTests {
    private func stub(_ harness: ContactsHarness) async throws {
        await harness.transport.stub(
            .propfind && .path("/remote.php/dav"), with: try .fixture("dav-current-user-principal.xml", status: 207))
        await harness.transport.stub(
            .propfind && .pathContains("/principals/users/") && .bodyContains("calendar-home-set"),
            with: try .fixture("dav-principal-home-sets.xml", status: 207))
        await harness.transport.stub(
            .propfind && .pathContains("/principals/users/") && .bodyContains("schedule-default-calendar-URL"),
            with: try .fixture("dav-principal-schedule-default.xml", status: 207))
        await harness.transport.stub(
            .propfind && .pathSuffix("/calendars/user"), with: try .fixture("dav-calendars-ws24.xml", status: 207))
    }

    @Test func mirrorsComponentsWritabilityColourAndTheDefault() async throws {
        let harness = try await ContactsHarness()
        try await stub(harness)
        let sync = CalendarListSync(store: harness.store, client: harness.client, loginId: harness.loginId)

        let listing = try #require(try await sync.runPass())

        let rows = try await harness.store.calendars(loginId: harness.loginId)
        #expect(rows.count == listing.count)
        // Inbox, outbox and trash bin are not calendars.
        #expect(
            !rows.contains {
                $0.url.hasSuffix("/inbox/") || $0.url.hasSuffix("/outbox/") || $0.url.hasSuffix("/trashbin/")
            })

        let personal = try #require(rows.first { $0.url.hasSuffix("/calendars/user/personal/") })
        #expect(personal.isWritable && personal.supportsEvents && !personal.supportsTasks)
        #expect(personal.color == "#00679e")
        #expect(personal.isDefaultSchedule)

        let birthdays = try #require(rows.first { $0.url.hasSuffix("/contact_birthdays/") })
        #expect(!birthdays.isWritable)  // no oc:read-only; the privilege set says so
        #expect(!birthdays.isDefaultSchedule)

        let tasks = try #require(rows.first { $0.url.hasSuffix("/ws17-tasks/") })
        #expect(tasks.supportsTasks && !tasks.supportsEvents && tasks.isWritable)
        #expect(tasks.color == nil)
        #expect(rows.filter(\.isDefaultSchedule).count == 1)
    }

    @Test func aFailedListingReplacesNothing() async throws {
        let harness = try await ContactsHarness()
        try await stub(harness)
        let sync = CalendarListSync(store: harness.store, client: harness.client, loginId: harness.loginId)
        _ = try await sync.runPass()
        let before = try await harness.store.calendars(loginId: harness.loginId)

        let failing = try await ContactsHarness()
        try await failing.store.replaceCalendars(
            before.map {
                var row = $0; row.id = nil; row.loginId = failing.loginId; return row
            },
            loginId: failing.loginId)
        await failing.transport.fail(.any, times: 10, then: .status(500))
        let broken = CalendarListSync(store: failing.store, client: failing.client, loginId: failing.loginId)

        #expect(await broken.syncNow() == nil)
        #expect(try await failing.store.calendars(loginId: failing.loginId).count == before.count)
    }
}
