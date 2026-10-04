// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import Testing

@testable import NextcloudMail

/// Itinerary cards (de-duplicated by UID, imported as the web builds the event) and the
/// "Reply with meeting" / "Create task" objects.
@Suite("Itinerary cards and calendar drafts")
struct CalendarItineraryTests {
    static func recorded() throws -> AnyJSON {
        try JSONDecoder().decode(AnyJSON.self, from: try FixtureBytes.data("message-itineraries-flight-ws34.json"))
    }

    @Test func recordedFlightBecomesOneImportableCard() throws {
        let entries = ItineraryEntry.entries(in: try Self.recorded(), remoteMessageId: 263)
        let flight = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(flight.kind == .flight)
        #expect(flight.departure == "TXL")
        #expect(flight.arrival == "MUC")
        #expect(flight.reservationNumber == "WS34AB")
        #expect(flight.title.contains("LH123"))
        // The web's UID: md5(messageId + IATA + number).
        #expect(flight.uid == CalendarObjects.md5Hex("263LH123"))
        #expect(flight.start == ISO8601DateFormatter().date(from: "2026-11-20T08:30:00Z"))
        #expect(flight.end == ISO8601DateFormatter().date(from: "2026-11-20T09:35:00Z"))
        #expect(flight.canImport)

        let event = try #require(flight.calendar()?.events.first)
        #expect(event.uid == flight.uid)
        #expect(event.start?.raw == "20261120T083000Z")
        #expect(event.end?.raw == "20261120T093500Z")
    }

    @Test func duplicateReservationsCollapseByUID() throws {
        guard case .array(let items) = try Self.recorded() else {
            Issue.record("the recorded itinerary is not an array")
            return
        }
        let doubled = AnyJSON.array(items + items)
        #expect(ItineraryEntry.entries(in: doubled, remoteMessageId: 263).count == 1)
        // The same reservation in another message is another event.
        #expect(
            ItineraryEntry.entries(in: doubled, remoteMessageId: 263).first?.uid
                != ItineraryEntry.entries(in: doubled, remoteMessageId: 264).first?.uid)
    }

    @Test func trainEventAndUnsupportedShapes() throws {
        let json = """
            [
              {"@type": "TrainReservation", "reservationFor": {"trainNumber": "ICE 1",
                "departureStation": {"name": "Berlin"}, "arrivalStation": {"name": "Munich"},
                "departureDay": "2026-12-01"}},
              {"@type": "EventReservation", "reservationFor": {"name": "Concert",
                "startDate": "2026-12-02T19:00:00+01:00",
                "location": {"name": "Hall", "geo": {"latitude": 1.5, "longitude": 2.5}}}},
              {"@type": "LodgingReservation", "reservationFor": {"name": "Hotel"}}
            ]
            """
        let data = try JSONDecoder().decode(AnyJSON.self, from: Data(json.utf8))
        let entries = ItineraryEntry.entries(in: data, remoteMessageId: 7)
        #expect(entries.count == 3)

        let train = try #require(entries.first)
        #expect(train.kind == .train)
        #expect(train.canImport)
        let trainEvent = try #require(train.calendar()?.events.first)
        #expect(trainEvent.start?.isDateOnly == true)
        #expect(trainEvent.start?.raw == "20261201")

        let concert = entries[1]
        #expect(concert.uid == CalendarObjects.md5Hex("7Concert"))
        #expect(concert.end == concert.start.map { $0.addingTimeInterval(7200) })
        let concertEvent = try #require(concert.calendar()?.events.first)
        #expect(concertEvent.location == "Hall")
        #expect(concertEvent.component.property("GEO")?.rawValue == "1.5;2.5")

        #expect(entries[2].kind == .unsupported("LodgingReservation"))
        #expect(!entries[2].canImport)
        #expect(entries[2].calendar() == nil)
    }

    @Test func meetingDraftInvitesTheOthersWithTheAccountAsOrganizer() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-04T10:20:00Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let draft = MeetingDraft.initial(
            subject: "Budget", preview: "Line one\n\nLine two",
            sender: Address(label: "Alice", email: "alice@example.net"),
            to: [
                Address(label: "Me", email: "Me@Example.com"), Address(label: nil, email: "bob@example.net"),
                Address(label: "Alice again", email: "ALICE@example.net"),
            ],
            addresses: ["me@example.com"], now: now, calendar: utc)
        #expect(draft.title == "Budget")
        #expect(draft.description == "Line one Line two")
        #expect(draft.attendees.map(\.email) == ["alice@example.net", "bob@example.net"])
        #expect(draft.start == ISO8601DateFormatter().date(from: "2026-10-04T11:00:00Z"))
        #expect(draft.end.timeIntervalSince(draft.start) == 3600)

        let organizer = MeetingAttendee(name: "Me", email: "me@example.com")
        let event = try #require(draft.calendar(uid: "m-1", organizer: organizer, now: now).events.first)
        #expect(event.uid == "m-1")
        #expect(event.organizer?.email == "me@example.com")
        #expect(event.attendees.compactMap(\.email) == ["alice@example.net", "bob@example.net"])
        #expect(event.attendees.allSatisfy { $0.partstat == .needsAction && $0.rsvp })
        #expect(event.start?.raw == "20261004T110000Z")

        var allDay = draft
        allDay.isAllDay = true
        let day = try #require(allDay.calendar(uid: "m-2", organizer: nil, now: now, zone: .gmt).events.first)
        #expect(day.start?.raw == "20261004")
        // Exclusive end: the day after.
        #expect(day.end?.raw == "20261005")
        #expect(day.attendees.isEmpty)
        #expect(day.organizer == nil)
    }

    @Test func taskDraftIsAVTODOWithTheWebsProperties() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-04T10:20:00Z"))
        var draft = TaskDraft.initial(subject: "Pay invoice", preview: "Due, soon; please")
        draft.due = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")
        let calendar = draft.calendar(uid: "t-1", now: now, zone: .gmt)
        let todo = try #require(calendar.todos.first)
        #expect(calendar.events.isEmpty)
        #expect(todo.uid == "t-1")
        #expect(todo.summary == "Pay invoice")
        #expect(todo.status == "NEEDS-ACTION")
        #expect(todo.due?.raw == "20261010")
        #expect(todo.component.property("DESCRIPTION")?.rawValue == "Due\\, soon\\; please")
        #expect(todo.component.property("X-OC-HIDESUBTASKS")?.rawValue == "0")
        #expect(todo.component.property("CREATED")?.rawValue == "20261004T102000Z")
        #expect(todo.component.property("DTSTART") == nil)

        draft.isAllDay = false
        #expect(draft.calendar(uid: "t-2", now: now).todos.first?.due?.raw == "20261010T120000Z")
    }
}
