// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// One iMIP object the server found in a message (`messageBody.schedulingJSON`, the web's
/// `scheduling` array), and everything the card decides from it. Values only.
struct CalendarInvitation: Equatable, Identifiable {
    enum Method: Equatable {
        case request
        case reply
        case cancel
        case other(String)

        init(_ raw: String) {
            switch raw.uppercased() {
            case "REQUEST": self = .request
            case "REPLY": self = .reply
            case "CANCEL": self = .cancel
            default: self = .other(raw)
            }
        }
    }

    /// What the card says and offers — the web `Imip.vue`'s branches.
    enum State: Equatable {
        /// REQUEST, the user is an attendee, no answer yet, and the event is ahead.
        case invited
        /// REQUEST the user answered: from this app (queued or sent), or already carried by
        /// the attached copy.
        case answered(ICalPartstat)
        /// REQUEST whose dates are behind us.
        case past
        /// REQUEST with no attendee matching any of the login's addresses.
        case notAttendee
        /// REPLY from one attendee.
        case replied(name: String, partstat: ICalPartstat?)
        /// REPLY with zero or several attendees ("This event was updated").
        case updated
        case cancelled
        /// A method the card does not handle (PUBLISH, COUNTER…): details only.
        case informational
    }

    /// The server's part id (`"1.2"`), stable for the message.
    let id: String
    let method: Method
    /// The attached object as sent, METHOD included.
    let calendar: ICalendar
    let event: ICalEvent

    var uid: String? { event.uid }

    /// Every iMIP object in a body's `schedulingJSON`. Entries that do not parse, or carry no
    /// VEVENT, are dropped: the card has nothing to show for them.
    static func invitations(schedulingJSON: String?) -> [CalendarInvitation] {
        guard let schedulingJSON,
            let entries = try? JSONDecoder().decode([AnyJSON].self, from: Data(schedulingJSON.utf8))
        else { return [] }
        return entries.enumerated().compactMap { index, entry in
            guard let fields = entry.objectValue,
                let contents = fields["contents"]?.stringValue,
                let calendar = try? ICalendar.parse(contents),
                let event = calendar.events.first
            else { return nil }
            let method = fields["method"]?.stringValue ?? calendar.method ?? ""
            return CalendarInvitation(
                id: fields["id"]?.stringValue ?? String(index),
                method: Method(method),
                calendar: calendar,
                event: event
            )
        }
    }

    /// The attendee line that is the user: the first ORGANIZER or ATTENDEE whose address is
    /// one of `addresses` (the login's account and alias addresses, lowercased). The web
    /// card searches ORGANIZER first too.
    func me(in addresses: Set<String>) -> ICalAttendee? {
        let lines = [event.organizer].compactMap { $0 } + event.attendees
        return lines.first { $0.email.map(addresses.contains) ?? false }
    }

    func state(addresses: Set<String>, answered: ICalPartstat? = nil, now: Date = Date()) -> State {
        switch method {
        case .request:
            guard let me = me(in: addresses) else { return .notAttendee }
            if let answered { return .answered(answered) }
            if let partstat = me.partstat, partstat != .needsAction { return .answered(partstat) }
            return isInFuture(now: now) ? .invited : .past
        case .reply:
            let attendees = event.attendees
            guard attendees.count == 1, let attendee = attendees.first else { return .updated }
            return .replied(name: attendee.commonName ?? attendee.email ?? attendee.uri, partstat: attendee.partstat)
        case .cancel:
            return .cancelled
        case .other:
            return .informational
        }
    }

    /// The web's `eventIsInFuture`. A recurring event counts as ahead unless its `UNTIL` is
    /// behind us — the web asks a recurrence engine for the next occurrence, which this
    /// app does not carry; a series with occurrences left is the case that matters.
    func isInFuture(now: Date) -> Bool {
        if let rule = event.recurrenceRule {
            guard let until = Self.until(in: rule) else { return true }
            return until > now
        }
        guard let start = event.start?.date else { return true }
        return start > now
    }

    private static func until(in rule: String) -> Date? {
        let parts = rule.split(separator: ";").map { $0.split(separator: "=", maxSplits: 1) }
        guard let value = parts.first(where: { $0.first?.uppercased() == "UNTIL" })?.last else { return nil }
        // Read through a DTSTART so NCMailCore's three date shapes apply to UNTIL as well.
        var component = ICalComponent(name: "VEVENT")
        component.addProperty(DirectoryProperty(name: "DTSTART", value: String(value)))
        return ICalEvent(component: component).start?.date
    }

    /// The object to `calendarPut` for the user's answer: the attached copy without METHOD,
    /// the user's PARTSTAT on their ATTENDEE line in every VEVENT of the object (a series
    /// and its overrides), RSVP cleared, and the comment as `X-RESPONSE-COMMENT` plus
    /// COMMENT — what the web card writes. Nil when the user is not on the invitation.
    func answer(_ partstat: ICalPartstat, comment: String?, addresses: Set<String>) -> ICalendar? {
        guard let email = me(in: addresses)?.email else { return nil }
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        var answered = CalendarObjects.storable(calendar)
        for index in answered.root.components.indices
        where answered.root.components[index].name.caseInsensitiveCompare("VEVENT") == .orderedSame {
            var event = ICalEvent(component: answered.root.components[index])
            event.setParticipation(of: email, to: partstat, comment: note)
            answered.root.components[index] = event.component
        }
        return answered
    }
}
