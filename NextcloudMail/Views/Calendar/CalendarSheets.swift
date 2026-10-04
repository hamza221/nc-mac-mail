// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// "Reply with meeting" — the web's `EventModal.vue`: an event prefilled from the message,
/// its title and description from the `eventData` server result (the thread's AI summary)
/// when the instance offers one, written through `calendarPut`.
struct MeetingSheet: View {
    let message: MessageViewModel
    let calendar: MessageCalendarModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var form = MeetingForm()
    @State private var newAddress = ""
    @State private var saving = false

    var body: some View {
        @Bindable var form = form
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $form.draft.title)
                if form.generation == .pending {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Generating event details…").foregroundStyle(.secondary)
                    }
                }
                Toggle("All day", isOn: $form.draft.isAllDay)
                DatePicker("From", selection: $form.draft.start, displayedComponents: components)
                DatePicker(
                    "To", selection: $form.draft.end, in: form.draft.start..., displayedComponents: components)
                CalendarPicker(title: "Calendar", calendars: calendar.eventCalendars, selection: $form.calendarId)
                Section("Attendees") {
                    ForEach(form.draft.attendees) { person in
                        HStack {
                            Text(verbatim: person.name.map { "\($0) <\(person.email)>" } ?? person.email)
                            Spacer()
                            Button {
                                form.draft.attendees.removeAll { $0.id == person.id }
                            } label: {
                                MailSymbol.remove.view(size: .small, label: .text("Remove \(person.email)"))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    TextField("Add attendee", text: $newAddress)
                        .onSubmit(addAttendee)
                }
                Section("Description") {
                    TextEditor(text: $form.draft.description)
                        .frame(minHeight: 100)
                }
            }
            .formStyle(.grouped)
            if let failure = calendar.failure {
                Text(failure).font(.caption).foregroundStyle(theme.colors.error.element).padding(.horizontal)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || target == nil || form.draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 560)
        .task { await form.prepare(message: message, calendar: calendar) }
    }

    private var components: DatePickerComponents { form.draft.isAllDay ? [.date] : [.date, .hourAndMinute] }

    private var target: CalendarRecord? {
        calendar.eventCalendars.first { $0.id == form.calendarId }
    }

    private func addAttendee() {
        let email = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !form.draft.attendees.contains(where: { $0.id == email.lowercased() }) else {
            return
        }
        form.draft.attendees.append(MeetingAttendee(name: nil, email: email))
        newAddress = ""
    }

    private func save() {
        guard let target else { return }
        saving = true
        Task {
            if await calendar.create(meeting: form.draft, organizer: form.organizer, in: target) {
                dismiss()
            }
            saving = false
        }
    }
}

/// The "Reply with meeting" form's state: the draft prefilled from the message, then the
/// thread's AI event data (`eventData`, keyed by the message — the server summarises its
/// thread root) over the title and description the reader has not changed.
///
/// "Not changed" is the field still holding what the form last put there, not "the binding
/// was written": a focused SwiftUI field writes its unchanged text back through the binding
/// as the sheet appears, which read as an edit and kept every AI answer out.
@MainActor
@Observable
final class MeetingForm {
    var draft = MeetingDraft(title: "", description: "", start: Date(), end: Date(), attendees: [])
    var calendarId: Int64?
    private(set) var organizer: MeetingAttendee?
    /// Pending while the AI answer is on its way; nil when it was not asked for.
    private(set) var generation: ServerResultState<MeetingSuggestion>?
    /// The title and description as the form last wrote them.
    @ObservationIgnored private var written = (title: "", description: "")

    func prepare(message: MessageViewModel, calendar: MessageCalendarModel) async {
        guard let header = message.header else { return }
        draft = MeetingDraft.initial(
            subject: header.subject, preview: message.bodyText, sender: header.sender, to: header.to,
            addresses: calendar.addresses)
        written = (draft.title, draft.description)
        calendarId = CalendarObjects.preferred(calendar.eventCalendars)?.id
        organizer = await calendar.organizer()
        // The web asks only when the instance has an LLM; nil means not discovered yet,
        // which the app treats as available (ADR-0079), and the server answers 204 if not.
        guard message.login?.llmSummariesAvailable != false, let loginId = message.resolvedLoginId else { return }
        generation = .pending
        await follow(key: ServerResultKind.messageKey(header.messageId), loginId: loginId, services: message.services)
    }

    /// Asks for the thread's event data and follows its row until the sheet closes.
    private func follow(key: String, loginId: Int64, services: MessageViewServices) async {
        let kind = ServerResultKind.eventData
        await services.serverResults?.request(kind: kind, key: key)
        do {
            for try await row in services.store.observeServerResult(kind: kind.rawValue, key: key, loginId: loginId) {
                guard let row else { continue }
                let payload = try? ServerResultPayload(payloadJSON: row.payloadJSON)
                generation = MessageViewModel.state(payload, MeetingSuggestion.init)
                if case .ready(let suggestion)? = generation { apply(suggestion) }
            }
        } catch {
            calendarLog.error("event data observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// The suggestion over each field the reader left as the form wrote it.
    func apply(_ suggestion: MeetingSuggestion) {
        if let title = suggestion.summary, draft.title == written.title {
            draft.title = title
            written.title = title
        }
        if let text = suggestion.description, draft.description == written.description {
            draft.description = text + "\n\n" + String(localized: "This description was generated by AI.")
            written.description = draft.description
        }
    }
}

/// The `eventData` row: `{"summary", "description"}`, either possibly null.
struct MeetingSuggestion: Equatable {
    var summary: String?
    var description: String?

    init?(_ data: AnyJSON) {
        guard let fields = data.objectValue else { return nil }
        summary = fields["summary"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        description = fields["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if summary == nil, description == nil { return nil }
    }
}

/// "Create task" — the web's `TaskModal.vue`: a VTODO in one of the login's task lists.
struct TaskSheet: View {
    let message: MessageViewModel
    let calendar: MessageCalendarModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var draft = TaskDraft(title: "", note: "")
    @State private var calendarId: Int64?
    @State private var hasStart = false
    @State private var hasDue = false
    @State private var start = Date()
    @State private var due = Date()
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if calendar.taskCalendars.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No task lists")
                    } icon: {
                        MailSymbol.task.view(size: .large, label: .decorative)
                    }
                } description: {
                    Text("Create a calendar with tasks in Nextcloud Calendar or Tasks to add tasks from mail.")
                }
            } else {
                Form {
                    TextField("Title", text: $draft.title)
                    CalendarPicker(title: "Task list", calendars: calendar.taskCalendars, selection: $calendarId)
                    Toggle("All day", isOn: $draft.isAllDay)
                    Toggle("Start", isOn: $hasStart)
                    if hasStart {
                        DatePicker("Start", selection: $start, displayedComponents: components).labelsHidden()
                    }
                    Toggle("Due", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Due", selection: $due, displayedComponents: components).labelsHidden()
                    }
                    Section("Note") {
                        TextEditor(text: $draft.note).frame(minHeight: 100)
                    }
                }
                .formStyle(.grouped)
            }
            if let failure = calendar.failure {
                Text(failure).font(.caption).foregroundStyle(theme.colors.error.element).padding(.horizontal)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || target == nil || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 440, minHeight: 440)
        .task {
            guard let header = message.header else { return }
            draft = TaskDraft.initial(subject: header.subject, preview: message.bodyText)
            calendarId = calendar.taskCalendars.first?.id
        }
    }

    private var components: DatePickerComponents { draft.isAllDay ? [.date] : [.date, .hourAndMinute] }

    private var target: CalendarRecord? {
        calendar.taskCalendars.first { $0.id == calendarId }
    }

    private func save() {
        guard let target else { return }
        var task = draft
        task.start = hasStart ? start : nil
        task.due = hasDue ? due : nil
        saving = true
        Task {
            if await calendar.create(task: task, in: target) {
                dismiss()
            }
            saving = false
        }
    }
}
