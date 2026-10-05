// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The calendar writes with no drainer — offline: each one waits in the queue as one
/// `calendarPut` row, and the cards read their own answer back from it.
@Suite("Calendar writes, offline")
@MainActor
struct CalendarActionsTests {
    private struct Fixture {
        let store: MailStore
        let queue: MutationQueue
        let actions: CalendarActions
        let personal: CalendarRecord
        let readOnly: CalendarRecord
        let tasks: CalendarRecord
        let loginId: Int64
        let accountId: Int64
    }

    private static let identity = ServerIdentity(serverURL: "https://cal.example.invalid/", loginName: "me")
    private static let base = "https://cal.example.invalid/remote.php/dav/calendars/me/"

    private func fixture() async throws -> Fixture {
        let store = try MailStore.inMemory()
        let loginId = try #require(try await store.ensureLogin(Self.identity).id)
        _ = try await store.upsert(accounts: [
            AccountWrite(
                identity: Self.identity, remoteId: 1, name: "Me", emailAddress: "user@example.com", rawJSON: "{}")
        ])
        try await store.replaceCalendars(
            [
                CalendarRecord(
                    loginId: loginId, url: Self.base + "personal/", displayName: "Personal", isDefaultSchedule: true,
                    fetchedAt: 0),
                CalendarRecord(
                    loginId: loginId, url: Self.base + "contact_birthdays/", displayName: "Birthdays",
                    isWritable: false, position: 1, fetchedAt: 0),
                CalendarRecord(
                    loginId: loginId, url: Self.base + "tasks/", displayName: "Tasks", supportsEvents: false,
                    supportsTasks: true, position: 2, fetchedAt: 0),
            ],
            loginId: loginId)
        let calendars = try await store.calendars(loginId: loginId)
        let client = DAVClient(
            server: try #require(URL(string: "https://cal.example.invalid/")),
            credentials: BasicCredentials(loginName: "me", appPassword: "x"))
        let queue = MutationQueue(
            store: store,
            configuration: MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: client)))
        let accountId = try await queue.queueAccountId(loginId: loginId)
        return Fixture(
            store: store, queue: queue, actions: CalendarActions(loginId: loginId, queue: queue),
            personal: try #require(calendars.first { $0.displayName == "Personal" }),
            readOnly: try #require(calendars.first { !$0.isWritable }),
            tasks: try #require(calendars.first { $0.supportsTasks }),
            loginId: loginId, accountId: accountId)
    }

    @Test func calendarChoicesFollowTheMirror() async throws {
        let f = try await fixture()
        let all = try await f.store.calendars(loginId: f.loginId)
        #expect(CalendarObjects.eventCalendars(all).map(\.displayName) == ["Personal"])
        #expect(CalendarObjects.taskCalendars(all).map(\.displayName) == ["Tasks"])
        #expect(CalendarObjects.preferred(CalendarObjects.eventCalendars(all))?.isDefaultSchedule == true)
    }

    @Test func anAnswerIsOneQueuedPutInTheChosenCalendar() async throws {
        let f = try await fixture()
        let invitation = try #require(
            CalendarInvitation.invitations(schedulingJSON: try CalendarInvitationTests.recordedSchedulingJSON()).first)
        try await f.actions.answer(
            invitation, .accepted, comment: "Yes", addresses: CalendarInvitationTests.me, in: f.personal)

        let writes = try await f.queue.pendingDAVWrites(loginId: f.loginId)
        let write = try #require(writes.first)
        #expect(writes.count == 1)
        #expect(write.kind == .calendarPut)
        #expect(write.payload.calendarId == f.personal.id)
        #expect(write.payload.collectionHref == "/remote.php/dav/calendars/me/personal/")
        #expect(write.payload.href?.hasPrefix("/remote.php/dav/calendars/me/personal/") == true)
        #expect(write.payload.href?.hasSuffix(".ics") == true)
        #expect(write.payload.etag == nil)
        let body = try #require(write.payload.body)
        #expect(!body.contains("METHOD"))
        let event = try #require(try ICalendar.parse(body).events.first)
        #expect(event.uid == invitation.uid)
        #expect(event.attendee(matching: "user@example.com")?.partstat == .accepted)

        // A reopened card reads the waiting answer back from the queue.
        let pending = await f.actions.pendingAnswer(
            uid: try #require(invitation.uid), addresses: CalendarInvitationTests.me)
        #expect(pending == .accepted)
        #expect(await f.actions.pendingAnswer(uid: "other", addresses: CalendarInvitationTests.me) == nil)
    }

    @Test func importSplitsTheFileByUIDWithItsTimezones() async throws {
        let f = try await fixture()
        let ics =
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nMETHOD:PUBLISH\r\n"
            + "BEGIN:VTIMEZONE\r\nTZID:Europe/Berlin\r\nEND:VTIMEZONE\r\n"
            + "BEGIN:VEVENT\r\nUID:a\r\nDTSTART;TZID=Europe/Berlin:20261112T090000\r\nSUMMARY:A\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nUID:a\r\nRECURRENCE-ID;TZID=Europe/Berlin:20261113T090000\r\n"
            + "DTSTART;TZID=Europe/Berlin:20261113T100000\r\nSUMMARY:A moved\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20261114T090000Z\r\nSUMMARY:B\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nDTSTART:20261115T090000Z\r\nSUMMARY:No UID\r\nEND:VEVENT\r\n"
            + "END:VCALENDAR\r\n"
        let count = try await f.actions.importFile(Data(ics.utf8), into: f.personal)
        #expect(count == 3)

        let bodies = try await f.queue.pendingDAVWrites(loginId: f.loginId).compactMap(\.payload.body)
        let objects = try bodies.map { try ICalendar.parse($0) }
        #expect(objects.count == 3)
        #expect(objects.allSatisfy { $0.method == nil })
        #expect(objects.map { $0.events.count } == [2, 1, 1])
        #expect(objects.allSatisfy { $0.timezones.count == 1 })
        #expect(objects[2].events.first?.uid?.isEmpty == false)
        #expect(Set(try await f.queue.pendingDAVWrites(loginId: f.loginId).compactMap(\.payload.href)).count == 3)
    }

    @Test func refusalsAreTyped() async throws {
        let f = try await fixture()
        var empty = ICalendar()
        empty.root.components = []
        await #expect(throws: CalendarActions.Failure.readOnly) {
            try await f.actions.put(empty, into: f.readOnly)
        }
        await #expect(throws: CalendarActions.Failure.nothingToImport) {
            try await f.actions.importFile(empty.serialize(), into: f.personal)
        }
        await #expect(throws: CalendarActions.Failure.noQueue) {
            try await CalendarActions(loginId: f.loginId, queue: nil).put(empty, into: f.personal)
        }
        #expect(try await f.queue.pendingDAVWrites(loginId: f.loginId).isEmpty)
    }

    @Test func aTaskLandsInTheTaskList() async throws {
        let f = try await fixture()
        try await f.actions.put(TaskDraft(title: "Follow up", note: "").calendar(uid: "t-9"), into: f.tasks)
        let write = try #require(try await f.queue.pendingDAVWrites(loginId: f.loginId).first)
        #expect(write.payload.collectionHref == "/remote.php/dav/calendars/me/tasks/")
        let body = try #require(write.payload.body)
        #expect(try ICalendar.parse(body).todos.first?.uid == "t-9")
    }

    /// The cards' model over a mirrored body: the invitation appears, the `.ics` attachment
    /// is not offered beside it, and an answer flips the card to "answered".
    @Test func modelShowsTheInvitationAndRecordsTheAnswer() async throws {
        let f = try await fixture()
        let model = MessageCalendarModel(
            services: MessageViewServices(
                store: f.store,
                client: MailClient(
                    server: try #require(URL(string: "https://cal.example.invalid/")),
                    credentials: BasicCredentials(loginName: "me", appPassword: "x"), clientVersion: "test"),
                server: try #require(URL(string: "https://cal.example.invalid/")),
                queue: f.queue))
        let mailboxes = try await f.store.upsert(
            mailboxes: [MailboxWrite(accountId: f.accountId, remoteId: 1, name: "INBOX", displayName: "Inbox")],
            accountId: f.accountId)
        let mailboxId = try #require(mailboxes.first).id
        let messageId = try await CalendarTestSupport.seedImipMessage(
            store: f.store, accountId: f.accountId, mailboxId: mailboxId)

        let task = Task {
            await model.run(
                .init(messageId: messageId, remoteId: 263, accountId: f.accountId, loginId: f.loginId))
        }
        defer { task.cancel() }
        try await CalendarTestSupport.until { !model.invitations.isEmpty && !model.calendars.isEmpty }

        let invitation = try #require(model.invitations.first)
        #expect(model.calendarAttachments.isEmpty)
        #expect(model.addresses.contains("user@example.com"))
        #expect(model.state(of: invitation, now: CalendarInvitationTests.before) == .invited)

        await model.answer(invitation, .tentative, comment: nil, in: model.eventCalendars.first)
        #expect(model.failure == nil)
        #expect(model.state(of: invitation, now: CalendarInvitationTests.before) == .answered(.tentative))
        #expect(try await f.queue.pendingDAVWrites(loginId: f.loginId).count == 1)
    }
}
