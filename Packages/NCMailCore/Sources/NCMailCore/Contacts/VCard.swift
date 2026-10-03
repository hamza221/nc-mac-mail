// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// A vCard as an ordered list of properties, lossless by construction.
///
/// `properties` is everything between `BEGIN:VCARD` and `END:VCARD`, in file
/// order, `VERSION` included. The typed accessors below interpret the common
/// properties; everything else — and every property this app never modified —
/// survives a round trip byte for byte, which is what lets another CardDAV
/// client's data pass through unharmed (ADR-0069, ADR-0075).
public struct VCard: Sendable, Equatable {
    public var properties: [DirectoryProperty]

    /// A new card. `VERSION` comes first because sabre rejects a card without
    /// one and some parsers insist it follows `BEGIN` immediately.
    public init(version: String = "3.0") {
        properties = [DirectoryProperty(name: "VERSION", value: version)]
    }

    init(properties: [DirectoryProperty]) {
        self.properties = properties
    }

    // MARK: - Property access

    /// The first property with this name, matched case-insensitively.
    public func property(_ name: String) -> DirectoryProperty? {
        properties.first { $0.isNamed(name) }
    }

    public func properties(_ name: String) -> [DirectoryProperty] {
        properties.filter { $0.isNamed(name) }
    }

    /// Replaces the first property with this name in place, keeping its
    /// position; appends before `END` order otherwise. Position stability is
    /// what keeps diffs reviewable on the server side.
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

    // MARK: - Typed accessors

    public var version: String? { property("VERSION")?.rawValue }
    public var uid: String? { property("UID")?.decodedValue() }
    public var formattedName: String? { property("FN")?.decodedValue() }
    public var nicknames: [String] {
        property("NICKNAME")?.decodedComponents(separator: ",").filter { !$0.isEmpty } ?? []
    }
    public var title: String? { property("TITLE")?.decodedValue() }
    public var note: String? { property("NOTE")?.decodedValue() }
    public var rev: String? { property("REV")?.rawValue }

    public var name: VCardName? {
        property("N").map { VCardName(components: $0.decodedComponents(separator: ";")) }
    }

    /// ORG's semicolon-separated units: organisation first, then departments.
    public var organization: [String] {
        property("ORG")?.decodedComponents(separator: ";").filter { !$0.isEmpty } ?? []
    }

    public var categories: [String] {
        properties("CATEGORIES").flatMap { $0.decodedComponents(separator: ",") }.filter { !$0.isEmpty }
    }

    public var emails: [VCardTypedValue] { typedValues("EMAIL") }
    public var phones: [VCardTypedValue] { typedValues("TEL") }
    public var urls: [VCardTypedValue] { typedValues("URL") }
    public var impps: [VCardTypedValue] { typedValues("IMPP") }
    public var socialProfiles: [VCardTypedValue] { typedValues("X-SOCIALPROFILE") }
    public var related: [VCardTypedValue] { typedValues("RELATED") }

    public var addresses: [VCardAddress] {
        properties("ADR").map { property in
            VCardAddress(
                components: property.decodedComponents(separator: ";"),
                types: VCard.types(of: property),
                label: property.parameter("LABEL")?.values.first.map(ContentLine.unescape)
            )
        }
    }

    public var birthday: VCardDate? { property("BDAY").map { VCardDate(raw: $0.rawValue) } }
    public var anniversary: VCardDate? { property("ANNIVERSARY").map { VCardDate(raw: $0.rawValue) } }

    public var photo: VCardPhoto? { property("PHOTO").map(VCardPhoto.init) }

    private func typedValues(_ name: String) -> [VCardTypedValue] {
        properties(name).map { property in
            VCardTypedValue(
                value: property.decodedValue(),
                types: VCard.types(of: property),
                isPreferred: VCard.isPreferred(property)
            )
        }
    }

    /// TYPE values plus vCard 2.1 bare tokens (`EMAIL;INTERNET:` carries its
    /// type as a parameter with no value).
    static func types(of property: DirectoryProperty) -> [String] {
        var types = property.parameterValues("TYPE")
        for parameter in property.parameters
        where parameter.values.isEmpty && !Self.nonTypeBareParameters.contains(parameter.name.uppercased()) {
            types.append(parameter.name)
        }
        return types
    }

    /// Both spellings of "preferred": vCard 3.0 `TYPE=PREF` and 4.0 `PREF=n`.
    static func isPreferred(_ property: DirectoryProperty) -> Bool {
        if property.parameterValues("TYPE").contains(where: { $0.caseInsensitiveCompare("PREF") == .orderedSame }) {
            return true
        }
        return property.parameter("PREF") != nil
    }

    private static let nonTypeBareParameters: Set<String> = ["ENCODING", "CHARSET", "VALUE", "LANGUAGE", "PREF"]
}

/// N, split: family, given, additional, prefixes, suffixes.
public struct VCardName: Sendable, Equatable {
    public var family: String
    public var given: String
    public var additional: String
    public var prefixes: String
    public var suffixes: String

    init(components: [String]) {
        family = components.count > 0 ? components[0] : ""
        given = components.count > 1 ? components[1] : ""
        additional = components.count > 2 ? components[2] : ""
        prefixes = components.count > 3 ? components[3] : ""
        suffixes = components.count > 4 ? components[4] : ""
    }
}

/// A value that carries TYPE information: EMAIL, TEL, URL, IMPP, RELATED…
public struct VCardTypedValue: Sendable, Equatable {
    public var value: String
    public var types: [String]
    public var isPreferred: Bool
}

/// ADR, split per RFC 6350 §6.3.1, with its TYPE list and optional LABEL.
public struct VCardAddress: Sendable, Equatable {
    public var postOfficeBox: String
    public var extended: String
    public var street: String
    public var locality: String
    public var region: String
    public var postalCode: String
    public var country: String
    public var types: [String]
    public var label: String?

    init(components: [String], types: [String], label: String?) {
        postOfficeBox = components.count > 0 ? components[0] : ""
        extended = components.count > 1 ? components[1] : ""
        street = components.count > 2 ? components[2] : ""
        locality = components.count > 3 ? components[3] : ""
        region = components.count > 4 ? components[4] : ""
        postalCode = components.count > 5 ? components[5] : ""
        country = components.count > 6 ? components[6] : ""
        self.types = types
        self.label = label
    }
}

/// BDAY and ANNIVERSARY, which arrive in several shapes: `1984-03-14`,
/// `19840314`, `--0214` (no year, vCard 4.0), `--02-14`, with or without a
/// time part. The raw text is kept; the components are best-effort.
public struct VCardDate: Sendable, Equatable {
    public var raw: String
    public var year: Int?
    public var month: Int?
    public var day: Int?

    init(raw: String) {
        self.raw = raw
        // Drop any time part; BDAY with a time is rare and the date is what the UI shows.
        let datePart = raw.split(separator: "T", maxSplits: 1)[0]
        if datePart.hasPrefix("--") {
            // --MMDD or --MM-DD
            let rest = datePart.dropFirst(2).replacingOccurrences(of: "-", with: "")
            if rest.count == 4 {
                month = Int(rest.prefix(2))
                day = Int(rest.suffix(2))
            }
            return
        }
        let digits = datePart.replacingOccurrences(of: "-", with: "")
        if digits.count == 8 {
            year = Int(digits.prefix(4))
            month = Int(digits.dropFirst(4).prefix(2))
            day = Int(digits.suffix(2))
        } else if digits.count == 6 {
            year = Int(digits.prefix(4))
            month = Int(digits.suffix(2))
        } else if digits.count == 4 {
            year = Int(digits)
        }
    }
}

/// PHOTO in either era: inline base64 (3.0 `ENCODING=b`, 2.1 `ENCODING=BASE64`,
/// 4.0 `data:` URI) or a fetchable URI.
public struct VCardPhoto: Sendable, Equatable {
    /// Decoded image bytes, when the photo is inline.
    public var data: Data?
    /// The URI, when the photo is a reference instead.
    public var uri: String?
    /// `TYPE=JPEG`/`MEDIATYPE=image/png`, normalised to nothing — passed through as written.
    public var mediaType: String?

    init(property: DirectoryProperty) {
        mediaType =
            property.parameter("MEDIATYPE")?.values.first
            ?? property.parameter("TYPE")?.values.first
        let raw = property.rawValue
        if let encoding = property.parameter("ENCODING")?.values.first,
            encoding.caseInsensitiveCompare("b") == .orderedSame
                || encoding.caseInsensitiveCompare("BASE64") == .orderedSame
        {
            data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
            return
        }
        if raw.lowercased().hasPrefix("data:") {
            // data:image/png;base64,....
            if let comma = raw.firstIndex(of: ",") {
                data = Data(base64Encoded: String(raw[raw.index(after: comma)...]), options: .ignoreUnknownCharacters)
                let header = raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]
                mediaType = header.split(separator: ";").first.map(String.init) ?? mediaType
            }
            return
        }
        uri = raw
    }
}
