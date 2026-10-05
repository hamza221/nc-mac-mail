// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import NCMailCore
import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// The calendar cards below the expanded message's banners (§5.9): the iMIP card, the
/// itinerary cards and `.ics` attachment import, each only when it applies; and the
/// host of the "Reply with meeting" and "Create task" sheets the ⋯ menu asks for.
/// See [ux-spec.md](../../../docs/product/ux-spec.md#calendar-in-the-message-view-ws-34).
struct MessageCalendarCards: View {
    let model: MessageViewModel

    @Environment(\.ncTheme) private var theme
    @State private var calendar: MessageCalendarModel?
    @State private var request: CalendarRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            if let calendar {
                ForEach(calendar.invitations) { invitation in
                    InvitationCard(invitation: invitation, model: calendar)
                }
                if !calendar.itinerary.isEmpty {
                    ItineraryCards(entries: calendar.itinerary, model: calendar)
                }
                ForEach(calendar.calendarAttachments, id: \.attachmentId) { attachment in
                    CalendarAttachmentImport(attachment: attachment, model: calendar)
                }
                if let failure = calendar.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(theme.colors.error.element)
                } else if let notice = calendar.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: contextKey) {
            guard let context = currentContext else { return }
            let calendar = self.calendar ?? MessageCalendarModel(services: model.services)
            self.calendar = calendar
            await calendar.run(context)
        }
        .onReceive(NotificationCenter.default.publisher(for: CalendarRequest.notification)) { note in
            guard let asked = CalendarRequest(note), asked.messageId == model.header?.messageId else { return }
            request = asked
        }
        .sheet(item: $request) { asked in
            if let calendar {
                switch asked.kind {
                case .meeting: MeetingSheet(message: model, calendar: calendar)
                case .task: TaskSheet(message: model, calendar: calendar)
                }
            }
        }
    }

    private var currentContext: MessageCalendarModel.Context? {
        guard let header = model.header, let loginId = model.resolvedLoginId else { return nil }
        return MessageCalendarModel.Context(
            messageId: header.messageId, remoteId: header.remoteId, accountId: header.accountId, loginId: loginId)
    }

    /// Restarts the observations when the expanded message changes or its login resolves.
    private var contextKey: String {
        "\(model.header?.messageId ?? -1)|\(model.resolvedLoginId ?? -1)"
    }
}

/// "Reply with meeting" or "Create task" for one message, asked for by the ⋯ menu and
/// presented by that message's `MessageCalendarCards`. A notification rather than a
/// binding: the menu and the cards are siblings in a view WS-30 owns, and each takes one
/// line there.
struct CalendarRequest: Identifiable, Equatable {
    enum Kind: String {
        case meeting
        case task
    }

    static let notification = Notification.Name("com.nextcloud.mail.calendarRequest")

    var messageId: Int64
    var kind: Kind

    var id: String { "\(messageId)|\(kind.rawValue)" }

    init(messageId: Int64, kind: Kind) {
        self.messageId = messageId
        self.kind = kind
    }

    init?(_ note: Notification) {
        guard let messageId = note.userInfo?["messageId"] as? Int64,
            let raw = note.userInfo?["kind"] as? String, let kind = Kind(rawValue: raw)
        else { return nil }
        self.init(messageId: messageId, kind: kind)
    }

    func post() {
        NotificationCenter.default.post(
            name: Self.notification, object: nil, userInfo: ["messageId": messageId, "kind": kind.rawValue])
    }
}

/// The ⋯ menu's calendar entries, in the web's place and wording: after "Edit as new
/// message".
struct CalendarMenuItems: View {
    let messageId: Int64

    var body: some View {
        Button("Reply with meeting") { CalendarRequest(messageId: messageId, kind: .meeting).post() }
        Button("Create task") { CalendarRequest(messageId: messageId, kind: .task).post() }
    }
}

/// A calendar choice, by name, over the mirror's calendar list.
struct CalendarPicker: View {
    let title: LocalizedStringKey
    let calendars: [CalendarRecord]
    @Binding var selection: Int64?

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(calendars, id: \.id) { calendar in
                Text(verbatim: calendar.displayName ?? calendar.url).tag(calendar.id)
            }
        }
    }
}
