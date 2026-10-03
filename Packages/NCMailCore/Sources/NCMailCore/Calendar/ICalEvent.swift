// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// RFC 5545 participation status. `other` keeps a value we do not model —
/// losing it would corrupt someone's delegation chain on the next write.
public enum ICalPartstat: Sendable, Equatable {
    case needsAction
    case accepted
    case declined
    case tentative
    case delegated
    case other(String)

    public init(rawValue: String) {
        switch rawValue.uppercased() {
        case "NEEDS-ACTION": self = .needsAction
        case "ACCEPTED": self = .accepted
        case "DECLINED": self = .declined
        case "TENTATIVE": self = .tentative
        case "DELEGATED": self = .delegated
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .declined: "DECLINED"
        case .tentative: "TENTATIVE"
        case .delegated: "DELEGATED"
        case .other(let value): value
        }
    }
}

/// One ATTENDEE or ORGANIZER line, read.
public struct ICalAttendee: Sendable, Equatable {
    public var property: DirectoryProperty

    init(property: DirectoryProperty) {
        self.property = property
    }

    /// The calendar user address as written, usually `mailto:…`.
    public var uri: String { property.rawValue }

    /// The address with a `mailto:` prefix stripped, lowercased for matching.
    public var email: String? {
        let raw = property.rawValue
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        return String(raw.dropFirst("mailto:".count)).lowercased()
    }

    public var commonName: String? { property.parameter("CN")?.values.first }
    public var role: String? { property.parameter("ROLE")?.values.first }
    public var rsvp: Bool {
        property.parameter("RSVP")?.values.first?.caseInsensitiveCompare("TRUE") == .orderedSame
    }
    public var partstat: ICalPartstat? {
        property.parameter("PARTSTAT")?.values.first.map(ICalPartstat.init(rawValue:))
    }
    /// The comment the Nextcloud clients attach to a participation answer,
    /// carried as an `X-RESPONSE-COMMENT` parameter on the ATTENDEE line
    /// (see nextcloud/mail's `Imip.vue`).
    public var responseComment: String? { property.parameter("X-RESPONSE-COMMENT")?.values.first }
}

/// DTSTART/DTEND/DUE in their three shapes: UTC (`…Z`), zoned (`TZID=`), or a
/// bare date. The raw text always survives; `date` is best-effort and nil for
/// a floating time, whose wall-clock meaning this app must not guess.
public struct ICalDateTime: Sendable, Equatable {
    public var raw: String
    public var timeZoneID: String?
    public var isDateOnly: Bool

    init(property: DirectoryProperty) {
        raw = property.rawValue
        timeZoneID = property.parameter("TZID")?.values.first
        isDateOnly =
            property.parameter("VALUE")?.values.first?.caseInsensitiveCompare("DATE") == .orderedSame
            || (!raw.contains("T") && raw.count == 8)
    }

    /// An absolute point in time, when one is defined: UTC forms always, zoned
    /// forms when the TZID is an Olson identifier the system knows. A date-only
    /// value answers midnight in the zone (or UTC without one).
    public var date: Date? {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        let zone: TimeZone?
        if raw.hasSuffix("Z") {
            zone = TimeZone(secondsFromGMT: 0)
        } else if let timeZoneID {
            zone = TimeZone(identifier: timeZoneID)
        } else if isDateOnly {
            zone = TimeZone(secondsFromGMT: 0)
        } else {
            zone = nil  // floating
        }
        guard let zone else { return nil }
        calendar.timeZone = zone

        let digits = raw.hasSuffix("Z") ? String(raw.dropLast()) : raw
        let parts = digits.split(separator: "T", maxSplits: 1)
        guard let datePart = parts.first, datePart.count == 8,
            let year = Int(datePart.prefix(4)),
            let month = Int(datePart.dropFirst(4).prefix(2)),
            let day = Int(datePart.suffix(2))
        else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        if parts.count == 2, parts[1].count >= 6 {
            components.hour = Int(parts[1].prefix(2))
            components.minute = Int(parts[1].dropFirst(2).prefix(2))
            components.second = Int(parts[1].dropFirst(4).prefix(2))
        }
        return calendar.date(from: components)
    }
}

/// A VEVENT, as a value. Mutations return through `ICalendar.replaceEvent`.
public struct ICalEvent: Sendable, Equatable {
    public var component: ICalComponent

    public init(component: ICalComponent) {
        self.component = component
    }

    /// A new event. DTSTAMP is required by RFC 5545 and stamped here so a
    /// caller cannot forget it.
    public init(
        uid: String,
        summary: String,
        start: DirectoryProperty,
        end: DirectoryProperty? = nil,
        location: String? = nil,
        description: String? = nil,
        timestamp: Date = Date()
    ) {
        var event = ICalComponent(name: "VEVENT")
        event.addProperty(DirectoryProperty(name: "UID", value: ContentLine.escape(uid)))
        event.addProperty(DirectoryProperty(name: "DTSTAMP", value: ICalEvent.utcTimestamp(timestamp)))
        event.addProperty(start)
        if let end { event.addProperty(end) }
        event.addProperty(DirectoryProperty(name: "SUMMARY", value: ContentLine.escape(summary)))
        if let location {
            event.addProperty(DirectoryProperty(name: "LOCATION", value: ContentLine.escape(location)))
        }
        if let description {
            event.addProperty(DirectoryProperty(name: "DESCRIPTION", value: ContentLine.escape(description)))
        }
        event.addProperty(DirectoryProperty(name: "SEQUENCE", value: "0"))
        component = event
    }

    /// A DTSTART/DTEND/DUE property for an absolute time, in UTC.
    public static func dateTimeProperty(_ name: String, utc date: Date) -> DirectoryProperty {
        DirectoryProperty(name: name, value: utcTimestamp(date))
    }

    /// A DTSTART/DTEND/DUE property for an all-day date.
    public static func dateProperty(_ name: String, year: Int, month: Int, day: Int) -> DirectoryProperty {
        DirectoryProperty(
            name: name,
            parameters: [DirectoryParameter(name: "VALUE", values: ["DATE"])],
            value: String(format: "%04d%02d%02d", year, month, day)
        )
    }

    public var uid: String? { component.property("UID")?.decodedValue() }
    public var summary: String? { component.property("SUMMARY")?.decodedValue() }
    public var location: String? { component.property("LOCATION")?.decodedValue() }
    public var eventDescription: String? { component.property("DESCRIPTION")?.decodedValue() }
    public var status: String? { component.property("STATUS")?.rawValue }
    public var sequence: Int { component.property("SEQUENCE").flatMap { Int($0.rawValue) } ?? 0 }
    public var start: ICalDateTime? { component.property("DTSTART").map(ICalDateTime.init) }
    public var end: ICalDateTime? { component.property("DTEND").map(ICalDateTime.init) }
    public var recurrenceRule: String? { component.property("RRULE")?.rawValue }
    public var organizer: ICalAttendee? { component.property("ORGANIZER").map(ICalAttendee.init) }
    public var attendees: [ICalAttendee] { component.properties("ATTENDEE").map(ICalAttendee.init) }
    /// The event-level copy of a participation comment (the web client writes
    /// both this and the attendee parameter).
    public var comment: String? { component.property("COMMENT")?.decodedValue() }

    public func attendee(matching email: String) -> ICalAttendee? {
        let needle = email.lowercased()
        return attendees.first { $0.email == needle }
    }

    /// What the Nextcloud Mail web client does when the user answers an
    /// invitation: PARTSTAT on the matching ATTENDEE, the comment both as an
    /// `X-RESPONSE-COMMENT` parameter there and as a COMMENT property. RSVP is
    /// cleared because the question has been answered.
    public mutating func setParticipation(of email: String, to partstat: ICalPartstat, comment: String? = nil) {
        let needle = email.lowercased()
        for (index, property) in component.properties.enumerated()
        where property.isNamed("ATTENDEE") && ICalAttendee(property: property).email == needle {
            var parameters = property.parameters.filter {
                $0.name.caseInsensitiveCompare("PARTSTAT") != .orderedSame
                    && $0.name.caseInsensitiveCompare("RSVP") != .orderedSame
                    && $0.name.caseInsensitiveCompare("X-RESPONSE-COMMENT") != .orderedSame
            }
            parameters.append(DirectoryParameter(name: "PARTSTAT", values: [partstat.rawValue]))
            if let comment {
                parameters.append(DirectoryParameter(name: "X-RESPONSE-COMMENT", values: [comment]))
            }
            component.properties[index] = DirectoryProperty(
                group: property.group,
                name: property.name,
                parameters: parameters,
                value: property.rawValue
            )
        }
        if let comment {
            component.setProperty("COMMENT", to: ContentLine.escape(comment))
        }
    }

    static func utcTimestamp(_ date: Date) -> String {
        utcFormatter.string(from: date)
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

/// A VTODO, as a value. The accessors mirror `ICalEvent` where VTODO shares
/// the property.
public struct ICalTodo: Sendable, Equatable {
    public var component: ICalComponent

    public init(component: ICalComponent) {
        self.component = component
    }

    /// A new task.
    public init(uid: String, summary: String, due: DirectoryProperty? = nil, timestamp: Date = Date()) {
        var todo = ICalComponent(name: "VTODO")
        todo.addProperty(DirectoryProperty(name: "UID", value: ContentLine.escape(uid)))
        todo.addProperty(DirectoryProperty(name: "DTSTAMP", value: ICalEvent.utcTimestamp(timestamp)))
        todo.addProperty(DirectoryProperty(name: "SUMMARY", value: ContentLine.escape(summary)))
        if let due { todo.addProperty(due) }
        todo.addProperty(DirectoryProperty(name: "STATUS", value: "NEEDS-ACTION"))
        component = todo
    }

    public var uid: String? { component.property("UID")?.decodedValue() }
    public var summary: String? { component.property("SUMMARY")?.decodedValue() }
    public var status: String? { component.property("STATUS")?.rawValue }
    public var due: ICalDateTime? { component.property("DUE").map(ICalDateTime.init) }
    public var percentComplete: Int? {
        component.property("PERCENT-COMPLETE").flatMap { Int($0.rawValue) }
    }
}
