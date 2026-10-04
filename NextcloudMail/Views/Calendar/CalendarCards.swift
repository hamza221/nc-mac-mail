// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

// Buttons sit beside each `NCNoteCard` rather than inside it: the card combines its
// children for VoiceOver, which makes a control inside it unreachable (library-feedback.md,
// WS-09).

// MARK: - iMIP

/// One invitation, reply or cancellation — the web's `Imip.vue`.
struct InvitationCard: View {
    let invitation: CalendarInvitation
    let model: MessageCalendarModel

    @Environment(\.ncTheme) private var theme
    @State private var showsMoreOptions = false
    @State private var comment = ""
    @State private var calendarId: Int64?

    var body: some View {
        let state = model.state(of: invitation)
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            NCNoteCard(role(for: state), title: headline(for: state)) {
                EventSummary(event: invitation.event)
            }
            if state == .invited {
                if showsMoreOptions { moreOptions }
                actions
            } else if state == .past {
                hint("This message has an attached invitation but the invitation dates are in the past")
            } else if state == .notAttendee {
                hint(
                    "This message has an attached invitation but the invitation does not contain a participant that matches any configured mail account address"
                )
            }
        }
        .onAppear { calendarId = calendarId ?? CalendarObjects.preferred(model.eventCalendars)?.id }
    }

    private var actions: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            Button("Accept") { answer(.accepted) }.buttonStyle(.secondary)
            Button("Decline") { answer(.declined) }.buttonStyle(.tertiary)
            Button("Tentatively accept") { answer(.tentative) }.buttonStyle(.tertiary)
            if !showsMoreOptions {
                Button("More options") { showsMoreOptions = true }.buttonStyle(.tertiary)
            }
            if isBusy { ProgressView().controlSize(.small) }
        }
        .disabled(isBusy || target == nil)
    }

    @ViewBuilder
    private var moreOptions: some View {
        // With "create tentative appointments" on, the server has put (or will put) the
        // event in the default calendar, and the answer has to update that copy: no choice.
        if model.imipCreate {
            hint("Your mail account adds invitations to your calendar, so your answer updates that event.")
        } else if model.eventCalendars.count > 1 {
            CalendarPicker(title: "Save to", calendars: model.eventCalendars, selection: $calendarId)
                .frame(maxWidth: 320)
        }
        TextField("Comment", text: $comment, axis: .vertical)
            .lineLimit(3...6)
            .frame(maxWidth: 480)
    }

    private var isBusy: Bool { invitation.uid.map(model.busy.contains) ?? false }

    private var target: CalendarRecord? {
        let calendars = model.eventCalendars
        if model.imipCreate { return CalendarObjects.preferred(calendars) }
        return calendars.first { $0.id == calendarId } ?? CalendarObjects.preferred(calendars)
    }

    private func answer(_ partstat: ICalPartstat) {
        let note = comment
        Task { await model.answer(invitation, partstat, comment: note, in: target) }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func role(for state: CalendarInvitation.State) -> NCNoteCard<EventSummary>.Role {
        switch state {
        case .cancelled: .error
        case .answered(.declined): .warning
        case .answered: .success
        default: .info
        }
    }

    private func headline(for state: CalendarInvitation.State) -> LocalizedStringResource {
        switch state {
        case .invited, .past: "You have been invited to an event"
        case .answered(.accepted): "You accepted this invitation"
        case .answered(.tentative): "You tentatively accepted this invitation"
        case .answered(.declined): "You declined this invitation"
        case .answered: "You already reacted to this invitation"
        case .notAttendee, .informational: "Calendar event"
        case .replied(let name, .accepted?): "\(name) accepted your invitation"
        case .replied(let name, .tentative?): "\(name) tentatively accepted your invitation"
        case .replied(let name, .declined?): "\(name) declined your invitation"
        case .replied(let name, _): "\(name) reacted to your invitation"
        case .updated: "This event was updated"
        case .cancelled: "This event was cancelled"
        }
    }
}

/// The event's title, time, place and people — the web's `EventData.vue`.
struct EventSummary: View {
    let event: ICalEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary = event.summary, !summary.isEmpty {
                Text(verbatim: summary).font(.headline)
            }
            if let when = Self.when(event) {
                Text(verbatim: when)
            }
            if let location = event.location, !location.isEmpty {
                Text(verbatim: location).foregroundStyle(.secondary)
            }
            if let organizer = event.organizer {
                Text("Organizer: \(organizer.commonName ?? organizer.email ?? organizer.uri)")
                    .foregroundStyle(.secondary)
            }
            if !event.attendees.isEmpty {
                Text("^[\(event.attendees.count) attendee](inflect: true)").foregroundStyle(.secondary)
            }
            if let text = event.eventDescription, !text.isEmpty {
                Text(verbatim: text).lineLimit(4).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    /// "12 Nov 2026, 10:00 – 10:30" in the reader's zone; an all-day event by date only.
    static func when(_ event: ICalEvent) -> String? {
        guard let start = event.start, let from = start.date else { return nil }
        let to = event.end?.date
        if start.isDateOnly {
            let style = Date.FormatStyle(date: .long, time: .omitted)
            // DTEND of an all-day event is exclusive.
            guard let to, to.timeIntervalSince(from) > 86_400 else { return from.formatted(style) }
            return "\(from.formatted(style)) – \(to.addingTimeInterval(-86_400).formatted(style))"
        }
        guard let to else { return from.formatted(date: .long, time: .shortened) }
        return (from..<max(to, from)).formatted(.interval.day().month(.abbreviated).year().hour().minute())
    }
}

// MARK: - Itineraries

/// The message's reservations, one card each — the web's `Itinerary.vue`.
struct ItineraryCards: View {
    let entries: [ItineraryEntry]
    let model: MessageCalendarModel

    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            ForEach(entries) { entry in
                if case .unsupported(let type) = entry.kind {
                    Text("Itinerary for \(type) is not supported yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: theme.metrics.spacing.standard) {
                        NCNoteCard(.info) { ItineraryDetails(entry: entry) }
                        if entry.canImport {
                            ImportMenu(
                                calendars: model.eventCalendars,
                                importedInto: model.imported[entry.uid],
                                isBusy: model.busy.contains(entry.uid)
                            ) { calendar in
                                Task { await model.importEntry(entry, into: calendar) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ItineraryDetails: View {
    let entry: ItineraryEntry

    var body: some View {
        HStack(alignment: .top) {
            symbol.view(size: .small, label: .decorative)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title).font(.headline)
                if let departure = entry.departure, let arrival = entry.arrival {
                    Text(verbatim: "\(departure) → \(arrival)")
                }
                if let start = entry.start {
                    if let end = entry.end {
                        Text((start..<max(end, start)).formatted(.interval.day().month(.abbreviated).hour().minute()))
                    } else {
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                    }
                } else if let day = entry.day {
                    // UTC midnight of the travel day, so read back in UTC.
                    Text(day.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
                }
                if let location = entry.location { Text(verbatim: location).foregroundStyle(.secondary) }
                if let number = entry.reservationNumber {
                    Text("Reservation \(number)").foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var symbol: MailSymbol {
        switch entry.kind {
        case .flight: .flight
        case .train: .train
        case .event, .unsupported: .calendar
        }
    }
}

// MARK: - .ics attachments

/// "Import into calendar" for one calendar attachment — the web's attachment action.
struct CalendarAttachmentImport: View {
    let attachment: AttachmentRecord
    let model: MessageCalendarModel

    @Environment(\.ncTheme) private var theme

    var body: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            MailSymbol.calendar.view(size: .small, label: .decorative)
            Text(verbatim: attachment.fileName ?? "invite.ics")
            ImportMenu(
                calendars: model.eventCalendars,
                importedInto: model.imported[attachment.attachmentId],
                isBusy: model.busy.contains(attachment.attachmentId)
            ) { calendar in
                Task { await model.importAttachment(attachment, into: calendar) }
            }
        }
    }
}

/// The web's `CalendarImport.vue`: a menu of writable calendars; "Imported into …" once done.
private struct ImportMenu: View {
    let calendars: [CalendarRecord]
    let importedInto: String?
    let isBusy: Bool
    let perform: (CalendarRecord) -> Void

    var body: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                ForEach(calendars, id: \.id) { calendar in
                    Button(calendar.displayName ?? calendar.url) { perform(calendar) }
                }
            } label: {
                if let importedInto {
                    Text("Imported into \(importedInto)")
                } else {
                    Text("Import into calendar")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(calendars.isEmpty)
            .help(calendars.isEmpty ? "No writable calendar" : "Import into calendar")
        }
    }
}
