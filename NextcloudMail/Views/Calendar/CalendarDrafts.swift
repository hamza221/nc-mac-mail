// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// One person on a meeting: the name to show and the address the ATTENDEE line carries.
struct MeetingAttendee: Equatable, Hashable, Identifiable {
    var name: String?
    var email: String

    var id: String { email.lowercased() }
}

/// The "Reply with meeting" form, as a value (the web's `EventModal.vue`).
struct MeetingDraft: Equatable {
    var title: String
    var description: String
    var start: Date
    var end: Date
    var isAllDay = false
    var attendees: [MeetingAttendee]

    /// The form as the sheet opens on `header`: the subject, the body's opening lines, the
    /// sender and the To recipients other than the user, and the next full hour for an
    /// hour. The web opens on "now → now"; an hour that has not started yet is the slot a
    /// reply proposes.
    static func initial(
        subject: String?, preview: String?, sender: Address?, to: [Address], addresses: Set<String>,
        now: Date = Date(), calendar: Calendar = .current
    ) -> MeetingDraft {
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        var seen = Set<String>()
        let people = ([sender].compactMap { $0 } + to).compactMap { address -> MeetingAttendee? in
            guard let email = address.email, !email.isEmpty, !addresses.contains(email.lowercased()),
                seen.insert(email.lowercased()).inserted
            else { return nil }
            return MeetingAttendee(name: address.label, email: email)
        }
        return MeetingDraft(
            title: subject ?? "",
            description: CalendarPreview.text(preview),
            start: hour,
            end: hour.addingTimeInterval(3600),
            attendees: people
        )
    }

    /// The event. With attendees, ORGANIZER is the account the message arrived in — the
    /// web writes the principal's address, which this app does not mirror; the account
    /// address is the one the attendees know.
    func calendar(
        uid: String = UUID().uuidString, organizer: MeetingAttendee?, now: Date = Date(), zone: TimeZone = .current
    )
        -> ICalendar
    {
        let startProperty: DirectoryProperty
        let endProperty: DirectoryProperty
        if isAllDay {
            startProperty = CalendarObjects.dateProperty("DTSTART", start, in: zone)
            // DTEND of an all-day event is exclusive: the day after the last one.
            let last = max(end, start)
            var days = Calendar(identifier: .gregorian)
            days.timeZone = zone
            let after = days.date(byAdding: .day, value: 1, to: last) ?? last
            endProperty = CalendarObjects.dateProperty("DTEND", after, in: zone)
        } else {
            startProperty = ICalEvent.dateTimeProperty("DTSTART", utc: start)
            endProperty = ICalEvent.dateTimeProperty("DTEND", utc: max(end, start))
        }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var event = ICalEvent(
            uid: uid, summary: title, start: startProperty, end: endProperty,
            description: text.isEmpty ? nil : text, timestamp: now)
        let invited = attendees.filter { $0.email.lowercased() != organizer?.email.lowercased() }
        if let organizer, !invited.isEmpty {
            for person in invited {
                event.component.addProperty(
                    Self.line(
                        "ATTENDEE", person,
                        extra: [
                            DirectoryParameter(name: "PARTSTAT", values: ["NEEDS-ACTION"]),
                            DirectoryParameter(name: "ROLE", values: ["REQ-PARTICIPANT"]),
                            DirectoryParameter(name: "RSVP", values: ["TRUE"]),
                        ]))
            }
            event.component.addProperty(Self.line("ORGANIZER", organizer, extra: []))
        }
        var calendar = ICalendar()
        calendar.root.components.append(event.component)
        return calendar
    }

    private static func line(
        _ name: String, _ person: MeetingAttendee, extra: [DirectoryParameter]
    ) -> DirectoryProperty {
        var parameters: [DirectoryParameter] = []
        if let label = person.name, !label.isEmpty {
            parameters.append(DirectoryParameter(name: "CN", values: [label]))
        }
        return DirectoryProperty(name: name, parameters: parameters + extra, value: "mailto:\(person.email)")
    }
}

/// The "Create task" form, as a value (the web's `TaskModal.vue`).
struct TaskDraft: Equatable {
    var title: String
    var note: String
    var start: Date?
    var due: Date?
    /// The web opens with "All day" on.
    var isAllDay = true

    static func initial(subject: String?, preview: String?) -> TaskDraft {
        TaskDraft(title: subject ?? "", note: CalendarPreview.text(preview))
    }

    /// The VTODO, with the properties the web's task model writes: CREATED, SUMMARY,
    /// DESCRIPTION (its "note"), DTSTART/DUE when set, and `X-OC-HIDESUBTASKS:0`.
    func calendar(uid: String = UUID().uuidString, now: Date = Date(), zone: TimeZone = .current) -> ICalendar {
        var todo = ICalTodo(uid: uid, summary: title, timestamp: now).component
        todo.addProperty(ICalEvent.dateTimeProperty("CREATED", utc: now))
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            todo.addProperty(DirectoryProperty(name: "DESCRIPTION", value: CalendarObjects.escape(text)))
        }
        if let start { todo.addProperty(property("DTSTART", start, zone: zone)) }
        if let due { todo.addProperty(property("DUE", due, zone: zone)) }
        todo.addProperty(DirectoryProperty(name: "X-OC-HIDESUBTASKS", value: "0"))
        var calendar = ICalendar()
        calendar.root.components.append(todo)
        return calendar
    }

    private func property(_ name: String, _ date: Date, zone: TimeZone) -> DirectoryProperty {
        isAllDay ? CalendarObjects.dateProperty(name, date, in: zone) : ICalEvent.dateTimeProperty(name, utc: date)
    }
}

/// The web fills both forms with the envelope's `previewText`: the body's opening, one
/// paragraph's worth.
enum CalendarPreview {
    static let limit = 255

    static func text(_ body: String?) -> String {
        guard let body else { return "" }
        let flattened = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }
}
