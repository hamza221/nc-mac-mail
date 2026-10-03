// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import Testing

@testable import NCMailCore

@Suite("iCalendar parsing, round trip and iMIP")
struct ICalendarTests {
    @Test func roundTripsEveryRecordedCalendarObject() throws {
        let names = try FixtureBytes.allNames().filter { $0.hasSuffix(".ics") }
        #expect(!names.isEmpty)
        for name in names {
            let original = try FixtureBytes.data(name)
            let calendar = try ICalendar.parse(original)
            let emitted = calendar.serialize()
            #expect(
                VCardTests.logicalLines(original) == VCardTests.logicalLines(emitted),
                "round trip of \(name) changed bytes beyond folding"
            )
        }
    }

    @Test func readsTheRecordedEvent() throws {
        let calendar = try ICalendar.parse(try FixtureBytes.data("event-standup.ics"))

        // The VTIMEZONE survives with its nested DAYLIGHT/STANDARD rules.
        #expect(calendar.timezones.count == 1)
        let timezone = try #require(calendar.timezones.first)
        #expect(timezone.property("TZID")?.rawValue == "Europe/Berlin")
        #expect(timezone.components.count == 2)

        let event = try #require(calendar.events.first)
        #expect(event.uid == "ws17-standup-1a2b")
        #expect(event.summary == "Daily standup")
        #expect(event.location == "Room 2")
        #expect(event.sequence == 0)
        #expect(event.status == "CONFIRMED")
        #expect(event.recurrenceRule == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")

        let start = try #require(event.start)
        #expect(start.timeZoneID == "Europe/Berlin")
        #expect(!start.isDateOnly)
        let date = try #require(start.date)
        var utc = Foundation.Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        // 09:30 Berlin in October is 07:30 UTC (CEST).
        #expect(utc.component(.hour, from: date) == 7)
        #expect(utc.component(.minute, from: date) == 30)

        #expect(event.organizer?.email == "organizer@nc.example")
        #expect(event.attendees.count == 2)
        let alice = try #require(event.attendee(matching: "alice.vance@initech.example"))
        #expect(alice.partstat == .needsAction)
        #expect(alice.rsvp)
        #expect(alice.commonName == "Alice Vance")
        #expect(alice.role == "REQ-PARTICIPANT")
        let bob = try #require(event.attendee(matching: "bob@globex.example"))
        #expect(bob.partstat == .accepted)
        #expect(!bob.rsvp)
    }

    @Test func readsTheRecordedTask() throws {
        let calendar = try ICalendar.parse(try FixtureBytes.data("todo-task.ics"))
        let todo = try #require(calendar.todos.first)
        #expect(todo.uid == "ws17-task-3c4d")
        #expect(todo.summary == "Write WS-17 report")
        #expect(todo.status == "NEEDS-ACTION")
        #expect(todo.percentComplete == 0)
        let due = try #require(todo.due)
        #expect(due.isDateOnly)
        #expect(due.raw == "20261010")
    }

    // MARK: - iMIP

    @Test func buildsAReplyWithPartstatAndComment() throws {
        let invitation = try ICalendar.parse(try FixtureBytes.data("event-standup.ics"))
        let reply = try #require(
            ICalendar.reply(
                to: invitation,
                from: "alice.vance@initech.example",
                partstat: .accepted,
                comment: "Happy to join, thanks",
                timestamp: Date(timeIntervalSince1970: 1_790_000_000)
            ))

        #expect(reply.method == "REPLY")
        let event = try #require(reply.events.first)
        #expect(event.uid == "ws17-standup-1a2b")
        #expect(event.sequence == 0)
        #expect(event.organizer?.email == "organizer@nc.example")

        // Exactly one attendee: the replier, with the new PARTSTAT, the RSVP
        // question dropped, and the comment where Nextcloud reads it.
        #expect(event.attendees.count == 1)
        let attendee = try #require(event.attendees.first)
        #expect(attendee.email == "alice.vance@initech.example")
        #expect(attendee.partstat == .accepted)
        #expect(!attendee.rsvp)
        #expect(attendee.responseComment == "Happy to join, thanks")
        #expect(event.comment == "Happy to join, thanks")

        // And all of that survives its own serialisation — the comment's comma
        // forces parameter quoting.
        let reparsed = try ICalendar.parse(reply.serialize())
        let survivor = try #require(reparsed.events.first?.attendees.first)
        #expect(survivor.responseComment == "Happy to join, thanks")
        #expect(survivor.partstat == .accepted)
    }

    @Test func replyFromAStrangerIsRefused() throws {
        let invitation = try ICalendar.parse(try FixtureBytes.data("event-standup.ics"))
        #expect(ICalendar.reply(to: invitation, from: "nobody@example.net", partstat: .declined) == nil)
    }

    @Test func buildsACancellation() throws {
        let invitation = try ICalendar.parse(try FixtureBytes.data("event-standup.ics"))
        let cancel = try #require(ICalendar.cancel(invitation))

        #expect(cancel.method == "CANCEL")
        let event = try #require(cancel.events.first)
        #expect(event.uid == "ws17-standup-1a2b")
        #expect(event.status == "CANCELLED")
        #expect(event.sequence == 1)  // bumped past the attendees' copies
        #expect(event.attendees.count == 2)  // they must all be told
        #expect(cancel.timezones.count == 1)
    }

    @Test func buildsARequestFromANewEvent() throws {
        let event = ICalEvent(
            uid: "new-event-1",
            summary: "Review; with an escaped semicolon",
            start: ICalEvent.dateTimeProperty("DTSTART", utc: Date(timeIntervalSince1970: 1_790_000_000)),
            end: ICalEvent.dateTimeProperty("DTEND", utc: Date(timeIntervalSince1970: 1_790_003_600)),
            location: "Room 1",
            timestamp: Date(timeIntervalSince1970: 1_789_000_000)
        )
        let request = ICalendar.request(event: event)
        #expect(request.method == "REQUEST")

        let reparsed = try ICalendar.parse(request.serialize())
        let parsed = try #require(reparsed.events.first)
        #expect(parsed.uid == "new-event-1")
        #expect(parsed.summary == "Review; with an escaped semicolon")
        #expect(parsed.location == "Room 1")
        #expect(parsed.start?.raw.hasSuffix("Z") == true)
        #expect(parsed.component.property("DTSTAMP") != nil)
    }

    @Test func createsATaskThatParsesBack() throws {
        let todo = ICalTodo(
            uid: "new-task-1",
            summary: "File the report",
            due: ICalEvent.dateProperty("DUE", year: 2026, month: 10, day: 10),
            timestamp: Date(timeIntervalSince1970: 1_789_000_000)
        )
        var calendar = ICalendar()
        calendar.root.components.append(todo.component)

        let parsed = try ICalendar.parse(calendar.serialize())
        let survivor = try #require(parsed.todos.first)
        #expect(survivor.uid == "new-task-1")
        #expect(survivor.summary == "File the report")
        #expect(survivor.due?.isDateOnly == true)
        #expect(survivor.due?.raw == "20261010")
    }

    @Test func setParticipationEditsTheAttendeeInPlace() throws {
        var calendar = try ICalendar.parse(try FixtureBytes.data("event-standup.ics"))
        var event = try #require(calendar.events.first)
        event.setParticipation(of: "alice.vance@initech.example", to: .tentative, comment: "Might be late")
        calendar.replaceEvent(event)

        let reparsed = try ICalendar.parse(calendar.serialize())
        let updated = try #require(reparsed.events.first)
        let alice = try #require(updated.attendee(matching: "alice.vance@initech.example"))
        #expect(alice.partstat == .tentative)
        #expect(alice.responseComment == "Might be late")
        #expect(alice.commonName == "Alice Vance")  // untouched parameters stay
        #expect(updated.comment == "Might be late")
        // The other attendee is untouched.
        #expect(updated.attendee(matching: "bob@globex.example")?.partstat == .accepted)
    }

    @Test func throwsOnMismatchedComponentNesting() {
        let text = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VCALENDAR\r\nEND:VEVENT\r\n"
        #expect(throws: DirectoryParseError.mismatchedEnd(expected: "VEVENT", found: "VCALENDAR")) {
            try ICalendar.parse(text)
        }
    }
}
