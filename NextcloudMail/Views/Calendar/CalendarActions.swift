// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// Every calendar write the message view makes, as queued `calendarPut` rows. No HTTP here:
/// the drainer sends each one when there is a network, so answering, importing and creating
/// all work offline. The handler re-targets a write whose UID the calendar already holds
/// onto the server's copy (ADR-0093) — which is what makes an invitation answer update the
/// copy scheduling delivered, and a second import of one itinerary update the first.
@MainActor
struct CalendarActions {
    enum Failure: Error, Equatable {
        /// The login's engine is not running: signed out, or not started yet.
        case noQueue
        case readOnly
        case badCalendarURL
        case nothingToImport
    }

    let loginId: Int64
    let queue: MutationQueue?

    /// Queues `object` as a new resource in `calendar`. Answers the href it was queued at.
    @discardableResult
    func put(_ object: ICalendar, into calendar: CalendarRecord) async throws -> String {
        guard let queue else { throw Failure.noQueue }
        guard calendar.isWritable else { throw Failure.readOnly }
        guard let collection = CalendarObjects.collectionPath(calendarURL: calendar.url),
            let href = CalendarObjects.newHref(calendarURL: calendar.url)
        else { throw Failure.badCalendarURL }
        let body = String(decoding: CalendarObjects.storable(object).serialize(), as: UTF8.self)
        let payload = DAVWritePayload(
            loginId: loginId,
            calendarId: calendar.id,
            collectionHref: collection,
            href: href,
            body: body,
            etag: nil,
            before: DAVWriteSnapshot(existed: false)
        )
        try await queue.perform(.calendarPut(payload), loginId: loginId)
        return href
    }

    /// The user's answer to an invitation, written into `calendar`.
    func answer(
        _ invitation: CalendarInvitation,
        _ partstat: ICalPartstat,
        comment: String?,
        addresses: Set<String>,
        in calendar: CalendarRecord
    ) async throws {
        guard let object = invitation.answer(partstat, comment: comment, addresses: addresses) else { return }
        try await put(object, into: calendar)
    }

    /// An `.ics` file split into one object per UID (the web's `importCalendarEvent`), each
    /// queued into `calendar`. Answers how many were queued.
    @discardableResult
    func importFile(_ data: Data, into calendar: CalendarRecord) async throws -> Int {
        let parsed = try ICalendar.parse(data)
        let objects = CalendarObjects.split(parsed)
        guard !objects.isEmpty else { throw Failure.nothingToImport }
        for (_, object) in objects {
            try await put(object, into: calendar)
        }
        return objects.count
    }

    /// The partstat of a queued answer to `uid` that has not reached the server yet, so a
    /// reopened card says "You accepted" while the row waits. Reads the queue, not the
    /// network.
    func pendingAnswer(uid: String, addresses: Set<String>) async -> ICalPartstat? {
        guard let queue, let writes = try? await queue.pendingDAVWrites(loginId: loginId) else { return nil }
        for write in writes.reversed() where write.kind == .calendarPut {
            guard let body = write.payload.body, body.contains(uid),
                let event = (try? ICalendar.parse(body))?.events.first, event.uid == uid
            else { continue }
            let mine = event.attendees.first { $0.email.map(addresses.contains) ?? false }
            if let partstat = mine?.partstat, partstat != .needsAction { return partstat }
        }
        return nil
    }
}
