// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync
import Observation
import os

nonisolated let calendarLog = Logger(subsystem: "com.nextcloud.mail.macos", category: "calendar")

/// The calendar cards' state for one expanded message, driven by the mirror.
///
/// Reads: the body row (`schedulingJSON`, attachments), the login's calendars, the
/// account's `imipCreate`, the login's account and alias addresses, and the `itinerary`
/// server result (ADR-0067). Writes: `calendarPut` rows through `CalendarActions`. Nothing
/// here reads a network response; the one network-adjacent call is
/// `ServerResultFetcher.request`, which answers nothing.
@MainActor
@Observable
final class MessageCalendarModel {
    struct Context: Equatable {
        var messageId: Int64
        var remoteId: Int64
        var accountId: Int64
        var loginId: Int64
    }

    private(set) var invitations: [CalendarInvitation] = []
    private(set) var itinerary: [ItineraryEntry] = []
    /// Calendar attachments offered for import — none when the message carries an iMIP
    /// object, whose card is the way to put that event in a calendar.
    private(set) var calendarAttachments: [AttachmentRecord] = []
    private(set) var calendars: [CalendarRecord] = []
    /// The login's account and alias addresses, lowercased: who "me" is on an invitation.
    private(set) var addresses: Set<String> = []
    /// The account's "Automatically create tentative appointments in calendar" (WS-39).
    private(set) var imipCreate = false
    /// Answers given from this app, by invitation UID: queued or already sent.
    private(set) var answers: [String: ICalPartstat] = [:]
    /// Itinerary UIDs and attachment ids imported this sitting, and where to.
    private(set) var imported: [String: String] = [:]
    private(set) var busy: Set<String> = []
    /// One sentence for the pane after a write, the web's toast.
    var notice: String?
    var failure: String?

    let services: MessageViewServices
    private(set) var context: Context?

    init(services: MessageViewServices) {
        self.services = services
    }

    var actions: CalendarActions? {
        context.map { CalendarActions(loginId: $0.loginId, queue: services.queue) }
    }

    var eventCalendars: [CalendarRecord] { CalendarObjects.eventCalendars(calendars) }
    var taskCalendars: [CalendarRecord] { CalendarObjects.taskCalendars(calendars) }

    func state(of invitation: CalendarInvitation, now: Date = Date()) -> CalendarInvitation.State {
        invitation.state(addresses: addresses, answered: invitation.uid.flatMap { answers[$0] }, now: now)
    }

    // MARK: - Observation

    /// Observes everything for `context` until the calling task is cancelled — the view's
    /// `.task(id:)`, which is cancelled when the expanded message changes.
    func run(_ context: Context) async {
        reset(to: context)
        await loadAddresses(context)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeBody(context) }
            group.addTask { await self.observeCalendars(context) }
            group.addTask { await self.observeItinerary(context) }
        }
    }

    private func reset(to context: Context) {
        self.context = context
        invitations = []
        itinerary = []
        calendarAttachments = []
        answers = [:]
        imported = [:]
        busy = []
        notice = nil
        failure = nil
    }

    private func loadAddresses(_ context: Context) async {
        let store = services.store
        guard let account = try? await store.account(id: context.accountId) else { return }
        imipCreate = account.imipCreate
        let identity = ServerIdentity(serverURL: account.serverURL, loginName: account.loginName)
        let accounts = (try? await store.accounts(identity: identity)) ?? [account]
        var found = Set<String>()
        for each in accounts {
            found.insert(each.emailAddress.lowercased())
            for alias in (try? await store.aliases(accountId: each.id)) ?? [] {
                found.insert(alias.email.lowercased())
            }
        }
        addresses = found
    }

    private func observeBody(_ context: Context) async {
        do {
            for try await stored in services.store.observeBody(messageId: context.messageId) {
                guard self.context == context else { return }
                let found = CalendarInvitation.invitations(schedulingJSON: stored?.body.schedulingJSON)
                if found != invitations {
                    invitations = found
                    await restorePendingAnswers(context)
                }
                let files = (stored?.attachments ?? []).filter(CalendarObjects.isCalendarAttachment)
                calendarAttachments = found.isEmpty ? files : []
            }
        } catch {
            calendarLog.error("body observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    private func observeCalendars(_ context: Context) async {
        do {
            for try await rows in services.store.observeCalendars(loginId: context.loginId) {
                guard self.context == context else { return }
                calendars = rows
            }
        } catch {
            calendarLog.error("calendar observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// Asks for the message's itinerary once (the row is kept 30 days) and follows the row.
    private func observeItinerary(_ context: Context) async {
        let kind = ServerResultKind.itinerary
        let key = ServerResultKind.messageKey(context.messageId)
        await services.serverResults?.request(kind: kind, key: key)
        do {
            for try await row in services.store.observeServerResult(
                kind: kind.rawValue, key: key, loginId: context.loginId)
            {
                guard self.context == context else { return }
                guard let row, case .ready(let data)? = try? ServerResultPayload(payloadJSON: row.payloadJSON) else {
                    itinerary = []
                    continue
                }
                itinerary = ItineraryEntry.entries(in: data, remoteMessageId: context.remoteId)
            }
        } catch {
            calendarLog.error("itinerary observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// A reopened card shows an answer still waiting in the queue rather than the buttons.
    private func restorePendingAnswers(_ context: Context) async {
        guard let actions else { return }
        for invitation in invitations {
            guard let uid = invitation.uid, answers[uid] == nil,
                let pending = await actions.pendingAnswer(uid: uid, addresses: addresses)
            else { continue }
            answers[uid] = pending
        }
    }

    // MARK: - Writes

    func answer(
        _ invitation: CalendarInvitation, _ partstat: ICalPartstat, comment: String?, in calendar: CalendarRecord?
    ) async {
        guard let uid = invitation.uid else { return }
        guard let actions, let calendar else {
            failure = String(localized: "There is no calendar to save your answer to.")
            return
        }
        await perform(key: uid) {
            try await actions.answer(invitation, partstat, comment: comment, addresses: self.addresses, in: calendar)
            self.answers[uid] = partstat
            self.notice = String(localized: "Your answer will be sent to the organizer.")
        }
    }

    func importEntry(_ entry: ItineraryEntry, into calendar: CalendarRecord) async {
        guard let actions, let object = entry.calendar() else { return }
        await perform(key: entry.uid) {
            try await actions.put(object, into: calendar)
            self.imported[entry.uid] = calendar.displayName ?? ""
            self.notice = String(localized: "Event imported into \(calendar.displayName ?? "")")
        }
    }

    func importAttachment(_ attachment: AttachmentRecord, into calendar: CalendarRecord) async {
        guard let actions, let context else { return }
        await perform(key: attachment.attachmentId) {
            let data = try await self.bytes(of: attachment, messageId: context.messageId)
            try await actions.importFile(data, into: calendar)
            self.imported[attachment.attachmentId] = calendar.displayName ?? ""
            self.notice = String(localized: "Event imported into \(calendar.displayName ?? "")")
        }
    }

    func create(meeting: MeetingDraft, organizer: MeetingAttendee?, in calendar: CalendarRecord) async -> Bool {
        guard let actions else { return false }
        return await perform(key: "meeting") {
            try await actions.put(meeting.calendar(organizer: organizer), into: calendar)
            self.notice = String(localized: "Event created")
        }
    }

    func create(task: TaskDraft, in calendar: CalendarRecord) async -> Bool {
        guard let actions else { return false }
        return await perform(key: "task") {
            try await actions.put(task.calendar(), into: calendar)
            self.notice = String(localized: "Task created")
        }
    }

    /// The organizer for a meeting from this message: the account it arrived in.
    func organizer() async -> MeetingAttendee? {
        guard let context, let account = try? await services.store.account(id: context.accountId) else { return nil }
        return MeetingAttendee(name: account.name, email: account.emailAddress)
    }

    @discardableResult
    private func perform(key: String, _ write: () async throws -> Void) async -> Bool {
        busy.insert(key)
        defer { busy.remove(key) }
        failure = nil
        notice = nil
        do {
            try await write()
            return true
        } catch {
            calendarLog.error("calendar write failed: \(RenderFailure.label(error), privacy: .public)")
            failure = Self.sentence(for: error)
            return false
        }
    }

    private static func sentence(for error: any Error) -> String {
        switch error {
        case CalendarActions.Failure.noQueue: String(localized: "Calendar changes need the account to be signed in.")
        case CalendarActions.Failure.readOnly: String(localized: "That calendar is read-only.")
        case CalendarActions.Failure.nothingToImport: String(localized: "The file has no events or tasks to import.")
        case is DirectoryParseError: String(localized: "The file is not a calendar file this app can read.")
        default: String(localized: "Could not save to the calendar.")
        }
    }

    /// The mirror's bytes when it has them, else the exporter's one-shot download into a
    /// temporary file — the same two sources Quick Look uses.
    private func bytes(of attachment: AttachmentRecord, messageId: Int64) async throws -> Data {
        if let data = attachment.data, !data.isEmpty { return data }
        guard let exporter = services.exporter else { throw MailAssetError.notStored }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "calendar-import-\(UUID().uuidString).ics")
        defer { try? FileManager.default.removeItem(at: url) }
        try await exporter.export(.attachment(id: attachment.attachmentId), messageId: messageId, to: url)
        return try Data(contentsOf: url)
    }
}
