// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// One reservation from the `itinerary` server result (the KItinerary JSON-LD array the
/// web's `Itinerary.vue` renders), reduced to what the card shows and the event it imports.
/// Values only.
struct ItineraryEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case flight
        case train
        case event
        /// A schema.org type the web does not render either ("Itinerary for {type} is not
        /// supported yet").
        case unsupported(String)
    }

    let kind: Kind
    /// The event's UID — the web's `md5(messageId + …)`, so the same reservation imported
    /// from either client is one calendar object. Also the de-duplication key.
    let uid: String
    let title: String
    let reservationNumber: String?
    let start: Date?
    let end: Date?
    /// A train with only a `departureDay`: imported as an all-day event.
    let day: Date?
    let location: String?
    /// `latitude;longitude`, for GEO.
    let geo: String?
    let departure: String?
    let arrival: String?

    var id: String { uid }

    /// The web's `canImport`: a flight needs both times; a train both times or a day; an
    /// event a start.
    var canImport: Bool {
        switch kind {
        case .flight: start != nil && end != nil
        case .train: (start != nil && end != nil) || day != nil
        case .event: start != nil
        case .unsupported: false
        }
    }

    /// The entries of a payload, de-duplicated by UID with the first kept. KItinerary often
    /// answers one reservation twice (once from the HTML's JSON-LD, once from a PDF or the
    /// text), and two cards importing one event is what the dedup prevents.
    /// `remoteMessageId` is the server's message id, the web's `messageId` prop.
    static func entries(in data: AnyJSON, remoteMessageId: Int64) -> [ItineraryEntry] {
        guard case .array(let items) = data else { return [] }
        var seen = Set<String>()
        var entries: [ItineraryEntry] = []
        for item in items {
            guard let entry = ItineraryEntry(item, remoteMessageId: remoteMessageId), seen.insert(entry.uid).inserted
            else { continue }
            entries.append(entry)
        }
        return entries
    }

    init?(_ item: AnyJSON, remoteMessageId: Int64) {
        guard let fields = item.objectValue, let type = fields["@type"]?.stringValue else { return nil }
        let reservation = fields["reservationFor"]?.objectValue ?? [:]
        let prefix = String(remoteMessageId)
        reservationNumber = fields["reservationNumber"]?.stringValue
        switch type {
        case "FlightReservation":
            let airline = reservation.object("airline")
            let number = (airline?.string("iataCode") ?? "") + (reservation.string("flightNumber") ?? "")
            let from = reservation.object("departureAirport")
            let to = reservation.object("arrivalAirport")
            let fromCode = from?.string("iataCode") ?? from?.string("name")
            let toCode = to?.string("iataCode") ?? to?.string("name")
            kind = .flight
            uid = CalendarObjects.md5Hex(prefix + number)
            departure = fromCode
            arrival = toCode
            title = String(
                localized: "Flight \(number) from \(fromCode ?? "") to \(toCode ?? "")",
                comment: "Itinerary event title, as the web client words it")
            start = Self.date(reservation["departureTime"])
            end = Self.date(reservation["arrivalTime"])
            day = nil
            location = nil
            geo = nil
        case "TrainReservation":
            let from = reservation.object("departureStation")?.string("name")
            let to = reservation.object("arrivalStation")?.string("name")
            kind = .train
            departure = from
            arrival = to
            start = Self.date(reservation["departureTime"])
            end = Self.date(reservation["arrivalTime"])
            day = reservation.string("departureDay").flatMap(Self.day)
            let name: String
            if let number = reservation.string("trainNumber") {
                name = String(
                    localized: "\(number) from \(from ?? "") to \(to ?? "")",
                    comment: "Itinerary train event title")
            } else {
                name = String(
                    localized: "Train from \(from ?? "") to \(to ?? "")", comment: "Itinerary train event title")
            }
            title = name
            // The web hashes its formatted departure time; the raw value is the stable part.
            uid = CalendarObjects.md5Hex(
                prefix + (Self.raw(reservation["departureTime"]) ?? reservation.string("departureDay") ?? name))
            location = nil
            geo = nil
        case "EventReservation":
            let name = reservation.string("name") ?? ""
            let place = reservation.object("location")
            let startDate = Self.date(reservation["startDate"])
            kind = .event
            title = name
            uid = CalendarObjects.md5Hex(prefix + name)
            start = startDate
            // The web assumes two hours when the reservation has no end.
            end = Self.date(reservation["endDate"]) ?? startDate.map { $0.addingTimeInterval(2 * 3600) }
            day = nil
            location = place?.string("name")
            if let point = place?.object("geo"), let latitude = point["latitude"]?.stringValue,
                let longitude = point["longitude"]?.stringValue
            {
                geo = "\(latitude);\(longitude)"
            } else {
                geo = nil
            }
            departure = nil
            arrival = nil
        default:
            kind = .unsupported(type)
            title = type
            uid = CalendarObjects.md5Hex(prefix + type + (fields["reservationNumber"]?.stringValue ?? ""))
            start = nil
            end = nil
            day = nil
            location = nil
            geo = nil
            departure = nil
            arrival = nil
        }
    }

    /// The VCALENDAR to import, or nil when `canImport` is false.
    func calendar(now: Date = Date()) -> ICalendar? {
        guard canImport else { return nil }
        let startProperty: DirectoryProperty
        var endProperty: DirectoryProperty?
        if let start {
            startProperty = ICalEvent.dateTimeProperty("DTSTART", utc: start)
            endProperty = end.map { ICalEvent.dateTimeProperty("DTEND", utc: $0) }
        } else if let day {
            startProperty = CalendarObjects.dateProperty("DTSTART", day, in: .gmt)
        } else {
            return nil
        }
        var event = ICalEvent(
            uid: uid, summary: title, start: startProperty, end: endProperty, location: location, timestamp: now)
        if let geo { event.component.addProperty(DirectoryProperty(name: "GEO", value: geo)) }
        var calendar = ICalendar()
        calendar.root.components.append(event.component)
        return calendar
    }

    // MARK: - JSON-LD values

    /// A schema.org date-time: a string, or KItinerary's `{"@type": "QDateTime", "@value",
    /// "timezone"}`. Both carry an offset, so the instant is exact without the zone.
    static func date(_ value: AnyJSON?) -> Date? {
        guard let text = raw(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func raw(_ value: AnyJSON?) -> String? {
        switch value {
        case .string(let text)?: text
        case .object(let fields)?: fields["@value"]?.stringValue
        default: nil
        }
    }

    /// `YYYY-MM-DD` at UTC midnight, which `dateProperty` turns back into the same day.
    private static func day(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }
}

extension [String: AnyJSON] {
    fileprivate func string(_ key: String) -> String? { self[key]?.stringValue }
    fileprivate func object(_ key: String) -> [String: AnyJSON]? { self[key]?.objectValue }
}
