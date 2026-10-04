// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import NCMailCore
import NCMailStore

/// Naming, shaping and choosing calendars for the objects the message view writes through
/// `calendarPut`. Values only: nothing here reads the store or the network.
enum CalendarObjects {
    /// The host-relative path of a calendar collection, slash-terminated, as a multistatus
    /// spells it.
    static func collectionPath(calendarURL: String) -> String? {
        guard let url = URL(string: calendarURL) else { return nil }
        var path = url.path(percentEncoded: true)
        guard !path.isEmpty else { return nil }
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    /// The host-relative href of a new object in `calendarURL`, named like the web client's
    /// `importCalendarEvent` (a random name, `.ics`).
    static func newHref(calendarURL: String, name: String = UUID().uuidString) -> String? {
        collectionPath(calendarURL: calendarURL).map { $0 + name + ".ics" }
    }

    /// `calendar` as a CalDAV server stores it. Sabre refuses an object with a `METHOD`
    /// property — 415 "A calendar object on a CalDAV server MUST NOT have a METHOD property",
    /// measured on the dev server — so an iMIP copy loses it before it is written.
    static func storable(_ calendar: ICalendar) -> ICalendar {
        var stored = calendar
        stored.root.removeProperties("METHOD")
        return stored
    }

    /// One object per UID, each carrying the file's VTIMEZONEs — the split the web client's
    /// `importCalendarEvent` makes, because a CalDAV object holds exactly one UID. A component
    /// without a UID gets a fresh one rather than being refused by the server. Order follows
    /// the file.
    static func split(_ calendar: ICalendar) -> [(uid: String, object: ICalendar)] {
        let kinds = ["VEVENT", "VTODO", "VJOURNAL"]
        var order: [String] = []
        var groups: [String: [ICalComponent]] = [:]
        for kind in kinds {
            for var component in calendar.root.components(kind) {
                let uid: String
                if let existing = component.property("UID")?.decodedValue(), !existing.isEmpty {
                    uid = existing
                } else {
                    uid = UUID().uuidString
                    component.setProperty("UID", to: uid)
                }
                let key = "\(kind)|\(uid)"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(component)
            }
        }
        return order.compactMap { key in
            guard let components = groups[key], let uid = key.split(separator: "|", maxSplits: 1).last else {
                return nil
            }
            var object = ICalendar()
            object.root.components.append(contentsOf: calendar.timezones)
            object.root.components.append(contentsOf: components)
            return (String(uid), object)
        }
    }

    /// RFC 5545 TEXT escaping, for SUMMARY/DESCRIPTION values built here.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case ";": escaped += "\\;"
            case ",": escaped += "\\,"
            case "\n", "\r\n": escaped += "\\n"
            case "\r": continue
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Lowercase hex MD5 — the web client names itinerary events `md5(messageId + …)`, and
    /// the same name here makes an import from either client land on one object.
    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// An all-day `VALUE=DATE` property for the calendar day `date` falls on in `zone`.
    static func dateProperty(_ name: String, _ date: Date, in zone: TimeZone = .current) -> DirectoryProperty {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return ICalEvent.dateProperty(name, year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    // MARK: - Choosing a calendar

    /// Writable calendars that take events: what "Save to" and "Import into" offer.
    static func eventCalendars(_ calendars: [CalendarRecord]) -> [CalendarRecord] {
        calendars.filter { $0.isWritable && $0.supportsEvents }
    }

    /// Writable calendars that take tasks: the web's task-calendar list.
    static func taskCalendars(_ calendars: [CalendarRecord]) -> [CalendarRecord] {
        calendars.filter { $0.isWritable && $0.supportsTasks }
    }

    /// The scheduling default calendar when it can take the object, else the first that can
    /// — the web's iMIP card preselects `schedule-default-calendar-URL` the same way.
    static func preferred(_ calendars: [CalendarRecord]) -> CalendarRecord? {
        calendars.first(where: \.isDefaultSchedule) ?? calendars.first
    }

    // MARK: - Attachments

    /// An attachment the user can import: the server's `isCalendarEvent`, a calendar MIME
    /// type, or an `.ics` name.
    static func isCalendarAttachment(_ attachment: AttachmentRecord) -> Bool {
        if attachment.isCalendarEvent { return true }
        let mime = attachment.mime?.lowercased() ?? ""
        if mime.hasPrefix("text/calendar") || mime.hasPrefix("application/ics") { return true }
        return attachment.fileName?.lowercased().hasSuffix(".ics") == true
    }
}
