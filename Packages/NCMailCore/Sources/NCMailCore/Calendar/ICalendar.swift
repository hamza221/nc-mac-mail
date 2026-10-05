// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// One iCalendar component: VCALENDAR, VEVENT, VTODO, VTIMEZONE, VALARM…
///
/// The same lossless shape as `VCard`: ordered `DirectoryProperty` values that
/// keep their original line, plus nested components in file order. Nothing in
/// here knows about mail — these are generic value types (ADR-0069).
public struct ICalComponent: Sendable, Equatable {
    public var name: String
    public var properties: [DirectoryProperty]
    public var components: [ICalComponent]

    public init(name: String, properties: [DirectoryProperty] = [], components: [ICalComponent] = []) {
        self.name = name
        self.properties = properties
        self.components = components
    }

    public func property(_ name: String) -> DirectoryProperty? {
        properties.first { $0.isNamed(name) }
    }

    public func properties(_ name: String) -> [DirectoryProperty] {
        properties.filter { $0.isNamed(name) }
    }

    public func components(_ name: String) -> [ICalComponent] {
        components.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public mutating func setProperty(_ name: String, to value: String, parameters: [DirectoryParameter] = []) {
        let replacement = DirectoryProperty(name: name, parameters: parameters, value: value)
        if let index = properties.firstIndex(where: { $0.isNamed(name) }) {
            properties[index] = replacement
        } else {
            properties.append(replacement)
        }
    }

    public mutating func addProperty(_ property: DirectoryProperty) {
        properties.append(property)
    }

    public mutating func removeProperties(_ name: String) {
        properties.removeAll { $0.isNamed(name) }
    }

    // MARK: - Lines

    func lines() -> [String] {
        var result = ["BEGIN:" + name]
        for property in properties {
            result.append(ContentLine.fold(property.serializedLine))
        }
        for child in components {
            result.append(contentsOf: child.lines())
        }
        result.append("END:" + name)
        return result
    }
}

/// A VCALENDAR with parse, serialise and the iMIP accessors WS-24 and the
/// message view need. Scope per the WS-17 brief: enough for REQUEST, REPLY and
/// CANCEL, participation status, and creating events and tasks.
public struct ICalendar: Sendable, Equatable {
    public var root: ICalComponent

    public init(root: ICalComponent) {
        self.root = root
    }

    /// A fresh VCALENDAR 2.0 wrapper.
    public init(method: String? = nil, prodID: String = ICalendar.defaultProdID) {
        var calendar = ICalComponent(name: "VCALENDAR")
        calendar.addProperty(DirectoryProperty(name: "VERSION", value: "2.0"))
        calendar.addProperty(DirectoryProperty(name: "PRODID", value: prodID))
        if let method {
            calendar.addProperty(DirectoryProperty(name: "METHOD", value: method))
        }
        root = calendar
    }

    public static let defaultProdID = "-//Nextcloud Mail (macOS)//EN"

    // MARK: - Parsing

    public static func parse(_ data: Data) throws(DirectoryParseError) -> ICalendar {
        let text =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    public static func parse(_ text: String) throws(DirectoryParseError) -> ICalendar {
        var stack: [ICalComponent] = []
        var finished: ICalComponent?
        for line in ContentLine.unfold(text) {
            let property = try ContentLine.parse(line)
            if property.isNamed("BEGIN") {
                stack.append(ICalComponent(name: property.rawValue))
                continue
            }
            if property.isNamed("END") {
                guard let open = stack.popLast() else {
                    throw .missingBegin(expected: property.rawValue)
                }
                guard open.name.caseInsensitiveCompare(property.rawValue) == .orderedSame else {
                    throw .mismatchedEnd(expected: open.name, found: property.rawValue)
                }
                if var parent = stack.popLast() {
                    parent.components.append(open)
                    stack.append(parent)
                } else if finished == nil, open.name.caseInsensitiveCompare("VCALENDAR") == .orderedSame {
                    finished = open
                }
                continue
            }
            if var top = stack.popLast() {
                top.properties.append(property)
                stack.append(top)
            }
            // Properties outside any component are dropped, as in VCardParser.
        }
        guard stack.isEmpty else { throw .unterminated(component: stack[stack.count - 1].name) }
        guard let calendar = finished else { throw .missingBegin(expected: "VCALENDAR") }
        return ICalendar(root: calendar)
    }

    // MARK: - Serialising

    public func serialize() -> Data {
        Data(root.lines().map { $0 + "\r\n" }.joined().utf8)
    }

    // MARK: - Accessors

    public var method: String? { root.property("METHOD")?.rawValue }
    public var prodID: String? { root.property("PRODID")?.rawValue }

    public var events: [ICalEvent] { root.components("VEVENT").map(ICalEvent.init) }
    public var todos: [ICalTodo] { root.components("VTODO").map(ICalTodo.init) }
    public var timezones: [ICalComponent] { root.components("VTIMEZONE") }

    /// Replaces the event with the same UID, so a mutated `ICalEvent` value can
    /// be written back. Appends when the UID is new.
    public mutating func replaceEvent(_ event: ICalEvent) {
        let uid = event.uid
        if let index = root.components.firstIndex(where: {
            $0.name.caseInsensitiveCompare("VEVENT") == .orderedSame && $0.property("UID")?.decodedValue() == uid
        }) {
            root.components[index] = event.component
        } else {
            root.components.append(event.component)
        }
    }
}
