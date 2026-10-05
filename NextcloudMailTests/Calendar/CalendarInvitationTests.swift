// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import Testing

@testable import NextcloudMail

/// The iMIP card's decisions (§5.9): which state an invitation is in, and the object an
/// answer writes.
@Suite("iMIP card states and answers")
struct CalendarInvitationTests {
    static let me: Set<String> = ["user@example.com"]
    /// Before the recorded invitation's 12 Nov 2026 09:00 UTC.
    static let before = Date(timeIntervalSince1970: 1_791_100_000)
    static let after = Date(timeIntervalSince1970: 1_800_000_000)

    /// The `scheduling` array of the recorded iMIP body, as the mirror stores it.
    static func recordedSchedulingJSON() throws -> String {
        let body = try JSONSerialization.jsonObject(with: try FixtureBytes.data("message-body-imip-ws34.json"))
        let scheduling = try #require((body as? [String: Any])?["scheduling"])
        return String(decoding: try JSONSerialization.data(withJSONObject: scheduling), as: UTF8.self)
    }

    static func scheduling(method: String, _ ics: String) throws -> String {
        let entry: [[String: Any]] = [["id": "1.2", "messageId": 1, "method": method, "contents": ics]]
        return String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    static func event(attendees: [String], method: String = "REQUEST", extra: String = "") -> String {
        let lines = attendees.joined(separator: "\r\n")
        return
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nMETHOD:\(method)\r\nBEGIN:VEVENT\r\nUID:card-1\r\nDTSTAMP:20261004T100000Z\r\nDTSTART:20261112T090000Z\r\nDTEND:20261112T093000Z\r\nSUMMARY:Planning\r\nORGANIZER;CN=Alice:mailto:alice@example.net\r\n\(lines)\r\n\(extra)END:VEVENT\r\nEND:VCALENDAR\r\n"
    }

    @Test func recordedRequestIsAnInvitationForTheAttendee() throws {
        let invitations = CalendarInvitation.invitations(schedulingJSON: try Self.recordedSchedulingJSON())
        let invitation = try #require(invitations.first)
        #expect(invitations.count == 1)
        #expect(invitation.method == .request)
        #expect(invitation.id == "1.2")
        #expect(invitation.uid == "ws34-imip-1791118152")
        #expect(invitation.state(addresses: Self.me, now: Self.before) == .invited)
        #expect(invitation.state(addresses: Self.me, now: Self.after) == .past)
        #expect(invitation.state(addresses: ["someone@else.example"], now: Self.before) == .notAttendee)
        // An answer given from this app wins over the attached NEEDS-ACTION.
        #expect(invitation.state(addresses: Self.me, answered: .declined, now: Self.before) == .answered(.declined))
        #expect(EventSummary.when(invitation.event) != nil)
    }

    @Test func addressMatchingIsCaseInsensitiveAndIncludesAliases() throws {
        let invitation = try #require(
            CalendarInvitation.invitations(
                schedulingJSON: try Self.scheduling(
                    method: "REQUEST",
                    Self.event(attendees: ["ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:Me.Alias@Example.ORG"]))
            ).first)
        #expect(invitation.state(addresses: ["me@example.org", "me.alias@example.org"], now: Self.before) == .invited)
    }

    @Test func attachedPartstatReadsAsAlreadyAnswered() throws {
        let invitation = try #require(
            CalendarInvitation.invitations(
                schedulingJSON: try Self.scheduling(
                    method: "REQUEST", Self.event(attendees: ["ATTENDEE;PARTSTAT=TENTATIVE:mailto:user@example.com"]))
            )
            .first)
        #expect(invitation.state(addresses: Self.me, now: Self.before) == .answered(.tentative))
    }

    @Test func replyAndCancelStates() throws {
        func state(_ method: String, _ attendees: [String]) throws -> CalendarInvitation.State? {
            CalendarInvitation.invitations(
                schedulingJSON: try Self.scheduling(method: method, Self.event(attendees: attendees, method: method))
            ).first?.state(addresses: Self.me, now: Self.before)
        }
        #expect(
            try state("REPLY", ["ATTENDEE;CN=Bob;PARTSTAT=ACCEPTED:mailto:bob@example.net"])
                == .replied(name: "Bob", partstat: .accepted))
        #expect(
            try state("REPLY", ["ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.net"])
                == .replied(name: "bob@example.net", partstat: .declined))
        #expect(
            try state(
                "REPLY", ["ATTENDEE:mailto:bob@example.net", "ATTENDEE:mailto:carol@example.net"]) == .updated)
        #expect(try state("CANCEL", ["ATTENDEE:mailto:user@example.com"]) == .cancelled)
        #expect(try state("PUBLISH", ["ATTENDEE:mailto:user@example.com"]) == .informational)
    }

    @Test func recurringSeriesIsAheadUntilItsUntil() throws {
        let open = try #require(
            CalendarInvitation.invitations(
                schedulingJSON: try Self.scheduling(
                    method: "REQUEST",
                    Self.event(attendees: ["ATTENDEE:mailto:user@example.com"], extra: "RRULE:FREQ=WEEKLY\r\n"))
            ).first)
        #expect(open.state(addresses: Self.me, now: Self.after) == .invited)
        let ended = try #require(
            CalendarInvitation.invitations(
                schedulingJSON: try Self.scheduling(
                    method: "REQUEST",
                    Self.event(
                        attendees: ["ATTENDEE:mailto:user@example.com"],
                        extra: "RRULE:FREQ=WEEKLY;UNTIL=20261201T000000Z\r\n"))
            ).first)
        #expect(ended.state(addresses: Self.me, now: Self.before) == .invited)
        #expect(ended.state(addresses: Self.me, now: Self.after) == .past)
    }

    /// The web card's write: PARTSTAT on the user's line only, RSVP cleared, the comment in
    /// both places, and no METHOD (Sabre 415s an object with one, measured).
    @Test func answerWritesPartstatOnTheUsersLineOnly() throws {
        let invitation = try #require(
            CalendarInvitation.invitations(schedulingJSON: try Self.recordedSchedulingJSON()).first)
        let answered = try #require(invitation.answer(.accepted, comment: "  See you there ", addresses: Self.me))
        let text = String(decoding: answered.serialize(), as: UTF8.self)
        let event = try #require(answered.events.first)
        let mine = try #require(event.attendee(matching: "user@example.com"))
        let alice = try #require(event.attendee(matching: "alice@example.net"))
        #expect(answered.method == nil)
        #expect(!text.contains("METHOD"))
        #expect(mine.partstat == .accepted)
        #expect(!mine.rsvp)
        #expect(mine.responseComment == "See you there")
        #expect(event.comment == "See you there")
        #expect(alice.partstat == .accepted)
        #expect(alice.role == "CHAIR")
        #expect(event.uid == invitation.uid)

        let declined = try #require(invitation.answer(.declined, comment: "   ", addresses: Self.me))
        let line = try #require(declined.events.first?.attendee(matching: "user@example.com"))
        #expect(line.partstat == .declined)
        #expect(line.responseComment == nil)
        #expect(declined.events.first?.comment == nil)
        #expect(invitation.answer(.accepted, comment: nil, addresses: ["stranger@example.org"]) == nil)
    }

    @Test func answerCoversEveryOccurrenceOverride() throws {
        let ics =
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nMETHOD:REQUEST\r\n"
            + "BEGIN:VEVENT\r\nUID:series\r\nDTSTART:20261112T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\n"
            + "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:user@example.com\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID:20261113T090000Z\r\nDTSTART:20261113T100000Z\r\n"
            + "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:user@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let invitation = try #require(
            CalendarInvitation.invitations(schedulingJSON: try Self.scheduling(method: "REQUEST", ics)).first)
        let answered = try #require(invitation.answer(.tentative, comment: nil, addresses: Self.me))
        #expect(answered.events.count == 2)
        #expect(answered.events.allSatisfy { $0.attendee(matching: "user@example.com")?.partstat == .tentative })
    }

    @Test func unreadableEntriesAreDropped() throws {
        #expect(CalendarInvitation.invitations(schedulingJSON: nil).isEmpty)
        #expect(CalendarInvitation.invitations(schedulingJSON: "not json").isEmpty)
        #expect(
            CalendarInvitation.invitations(schedulingJSON: try Self.scheduling(method: "REQUEST", "BEGIN:VCARD"))
                .isEmpty)
    }
}
