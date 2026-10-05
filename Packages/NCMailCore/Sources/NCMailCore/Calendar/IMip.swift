// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// The three iMIP (RFC 6047) messages this client composes. Incoming objects
/// of any method parse through `ICalendar.parse` unchanged.
extension ICalendar {
    /// An invitation: METHOD:REQUEST carrying the event and its timezones.
    public static func request(event: ICalEvent, timezones: [ICalComponent] = []) -> ICalendar {
        var calendar = ICalendar(method: "REQUEST")
        calendar.root.components.append(contentsOf: timezones)
        calendar.root.components.append(event.component)
        return calendar
    }

    /// An attendee's answer to an invitation: METHOD:REPLY with a minimal
    /// VEVENT per RFC 5546 §3.2.3 — UID, SEQUENCE, ORGANIZER, and exactly one
    /// ATTENDEE: the replier, with the new PARTSTAT and, when the user typed
    /// one, the comment in the two places Nextcloud looks for it
    /// (`X-RESPONSE-COMMENT` on the attendee, COMMENT on the event).
    ///
    /// Returns nil when `attendeeEmail` is not on the invitation — a REPLY
    /// from a stranger would be discarded by every scheduling broker anyway.
    public static func reply(
        to invitation: ICalendar,
        from attendeeEmail: String,
        partstat: ICalPartstat,
        comment: String? = nil,
        timestamp: Date = Date()
    ) -> ICalendar? {
        guard let event = invitation.events.first,
            let attendee = event.attendee(matching: attendeeEmail),
            let uid = event.uid
        else { return nil }

        var replyEvent = ICalComponent(name: "VEVENT")
        replyEvent.addProperty(DirectoryProperty(name: "UID", value: ContentLine.escape(uid)))
        replyEvent.addProperty(
            DirectoryProperty(name: "DTSTAMP", value: ICalEvent.utcTimestamp(timestamp)))
        replyEvent.addProperty(DirectoryProperty(name: "SEQUENCE", value: String(event.sequence)))
        if let organizer = event.organizer {
            replyEvent.addProperty(organizer.property)
        }

        var parameters = attendee.property.parameters.filter {
            $0.name.caseInsensitiveCompare("PARTSTAT") != .orderedSame
                && $0.name.caseInsensitiveCompare("RSVP") != .orderedSame
                && $0.name.caseInsensitiveCompare("X-RESPONSE-COMMENT") != .orderedSame
        }
        parameters.append(DirectoryParameter(name: "PARTSTAT", values: [partstat.rawValue]))
        if let comment {
            parameters.append(DirectoryParameter(name: "X-RESPONSE-COMMENT", values: [comment]))
        }
        replyEvent.addProperty(
            DirectoryProperty(name: "ATTENDEE", parameters: parameters, value: attendee.property.rawValue))
        if let comment {
            replyEvent.addProperty(DirectoryProperty(name: "COMMENT", value: ContentLine.escape(comment)))
        }
        // The organiser matches replies against the slot it sent, so the
        // original DTSTART travels along when present.
        if let start = event.component.property("DTSTART") {
            replyEvent.addProperty(start)
        }

        var calendar = ICalendar(method: "REPLY")
        calendar.root.components.append(replyEvent)
        return calendar
    }

    /// The organiser withdraws the event: METHOD:CANCEL, STATUS:CANCELLED, and
    /// a SEQUENCE bumped past every copy the attendees hold (RFC 5546 §3.2.5).
    public static func cancel(
        _ invitation: ICalendar,
        timestamp: Date = Date()
    ) -> ICalendar? {
        guard let event = invitation.events.first else { return nil }
        var cancelled = event.component
        cancelled.setProperty("DTSTAMP", to: ICalEvent.utcTimestamp(timestamp))
        cancelled.setProperty("SEQUENCE", to: String(event.sequence + 1))
        cancelled.setProperty("STATUS", to: "CANCELLED")

        var calendar = ICalendar(method: "CANCEL")
        calendar.root.components.append(contentsOf: invitation.timezones)
        calendar.root.components.append(cancelled)
        return calendar
    }
}
