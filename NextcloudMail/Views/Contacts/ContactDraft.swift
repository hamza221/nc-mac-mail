// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// The contact editor's working copy: every typed vCard property as an editable field, laid
/// over the card it came from.
///
/// ``card(now:)`` writes back only what changed. A property the user did not touch keeps its
/// original line byte for byte (``DirectoryProperty/rawLine``), a changed one keeps its group
/// and every parameter except `TYPE`, and a property this editor does not know is never
/// touched at all — that is what lets another CardDAV client's data survive an edit here
/// (ADR-0069, ADR-0075).
nonisolated struct ContactDraft: Equatable, Sendable {
    /// The multi-valued properties, each a list of typed rows.
    enum Kind: String, CaseIterable, Sendable {
        case email = "EMAIL"
        case phone = "TEL"
        case address = "ADR"
        case url = "URL"
        case impp = "IMPP"
        case social = "X-SOCIALPROFILE"
        case related = "RELATED"

        /// The type choices web Contacts offers for the property (`rfcProps`), first is the
        /// default for a new row.
        var typeChoices: [String] {
            switch self {
            case .email: ["HOME", "WORK", "OTHER"]
            case .phone: ["CELL", "HOME", "WORK", "FAX", "PAGER", "VOICE", "CAR", "OTHER"]
            case .address: ["HOME", "WORK", "OTHER"]
            case .url: ["HOME", "WORK", "OTHER"]
            case .impp: ["XMPP", "SKYPE", "MATRIX", "TELEGRAM", "SIGNAL", "OTHER"]
            case .social: ["FACEBOOK", "INSTAGRAM", "MASTODON", "TUMBLR", "DIASPORA", "XING", "TELEGRAM", "OTHER"]
            case .related: ["SPOUSE", "CHILD", "PARENT", "SIBLING", "FRIEND", "COLLEAGUE", "OTHER"]
            }
        }

        /// URI-valued in vCard: written verbatim, never text-escaped.
        var isURI: Bool { self == .url || self == .impp || self == .social || self == .related }

        var title: String {
            switch self {
            case .email: String(localized: "Email")
            case .phone: String(localized: "Phone")
            case .address: String(localized: "Address")
            case .url: String(localized: "Website")
            case .impp: String(localized: "Instant messaging")
            case .social: String(localized: "Social network")
            case .related: String(localized: "Related")
            }
        }

        /// A TYPE value as a label: the known ones translated, the rest as written.
        static func typeLabel(_ type: String) -> String {
            switch type.uppercased() {
            case "HOME": String(localized: "Home")
            case "WORK": String(localized: "Work")
            case "OTHER": String(localized: "Other")
            case "CELL": String(localized: "Mobile")
            case "FAX": String(localized: "Fax")
            case "PAGER": String(localized: "Pager")
            case "VOICE": String(localized: "Voice")
            case "CAR": String(localized: "Car")
            case "SPOUSE": String(localized: "Spouse")
            case "CHILD": String(localized: "Child")
            case "PARENT": String(localized: "Parent")
            case "SIBLING": String(localized: "Sibling")
            case "FRIEND": String(localized: "Friend")
            case "COLLEAGUE": String(localized: "Colleague")
            case "": String(localized: "No type")
            default: type.capitalized
            }
        }
    }

    /// One row of a multi-valued property. `source` is the index in ``base`` it came from,
    /// nil for a row the user added.
    struct Field: Identifiable, Equatable, Sendable {
        var id = UUID()
        var kind: Kind
        var type: String
        var value: String
        /// ADR's seven components: PO box, extended, street, locality, region, postal code,
        /// country. Empty for every other kind.
        var address: [String] = []
        var source: Int?

        var isEmpty: Bool {
            kind == .address ? address.allSatisfy { $0.isEmpty } : value.isEmpty
        }

        /// Content equality: the id only keeps SwiftUI rows stable across edits.
        static func == (lhs: Field, rhs: Field) -> Bool {
            lhs.kind == rhs.kind && lhs.type == rhs.type && lhs.value == rhs.value && lhs.address == rhs.address
                && lhs.source == rhs.source
        }
    }

    /// What happens to PHOTO on save.
    enum PhotoChange: Equatable, Sendable {
        case unchanged
        case removed
        /// Image bytes and their subtype (`jpeg`, `png`).
        case set(Data, subtype: String)
    }

    let base: VCard
    var prefix: String
    var given: String
    var additional: String
    var family: String
    var suffix: String
    var formattedName: String
    var nickname: String
    var organization: String
    var department: String
    var title: String
    var birthday: String
    var anniversary: String
    var note: String
    var categories: [String]
    var fields: [Field]
    var photo: PhotoChange = .unchanged

    /// Properties the editor owns: everything else is "other", shown read-only and passed
    /// through untouched.
    static let handled: Set<String> = Set([
        "VERSION", "UID", "REV", "PRODID", "FN", "N", "NICKNAME", "ORG", "TITLE", "NOTE", "BDAY",
        "ANNIVERSARY", "CATEGORIES", "PHOTO",
    ]).union(Kind.allCases.map(\.rawValue))

    init(card: VCard) {
        base = card
        let name = card.name
        prefix = name?.prefixes ?? ""
        given = name?.given ?? ""
        additional = name?.additional ?? ""
        family = name?.family ?? ""
        suffix = name?.suffixes ?? ""
        formattedName = card.formattedName ?? ""
        nickname = card.nicknames.joined(separator: ", ")
        let org = card.property("ORG")?.decodedComponents(separator: ";") ?? []
        organization = org.first ?? ""
        department = org.dropFirst().joined(separator: ";")
        title = card.title ?? ""
        birthday = card.property("BDAY")?.decodedValue() ?? ""
        anniversary = card.property("ANNIVERSARY")?.decodedValue() ?? ""
        note = card.note ?? ""
        categories = card.categories
        var fields: [Field] = []
        for (index, property) in card.properties.enumerated() {
            guard let kind = Kind.allCases.first(where: { property.isNamed($0.rawValue) }) else { continue }
            let types = Self.types(of: property)
            if kind == .address {
                var parts = property.decodedComponents(separator: ";")
                parts += Array(repeating: "", count: max(0, 7 - parts.count))
                fields.append(Field(kind: kind, type: types, value: "", address: Array(parts.prefix(7)), source: index))
            } else {
                fields.append(Field(kind: kind, type: types, value: property.decodedValue(), source: index))
            }
        }
        self.fields = fields
    }

    /// A new person's card, as web Contacts starts one: `UID`, and the group the list was
    /// showing when New contact was pressed.
    static func new(uid: String, categories: [String] = []) -> ContactDraft {
        var card = VCard()
        card.setProperty("UID", to: uid)
        var draft = ContactDraft(card: card)
        draft.categories = categories
        return draft
    }

    /// Whether anything differs from ``base``.
    var hasChanges: Bool { self != ContactDraft(card: base) }

    /// The read-only rest of the card: every property this editor does not own.
    var otherProperties: [DirectoryProperty] {
        base.properties.filter { !Self.handled.contains($0.name.uppercased()) }
    }

    /// The name to save under FN when the user left it empty: the parts of N, else the
    /// organisation — sabre fills a missing FN itself, but with less care.
    var effectiveFormattedName: String {
        if !formattedName.trimmingCharacters(in: .whitespaces).isEmpty { return formattedName }
        let parts = [prefix, given, additional, family, suffix].filter { !$0.isEmpty }
        return parts.isEmpty ? organization : parts.joined(separator: " ")
    }

    func fields(_ kind: Kind) -> [Field] { fields.filter { $0.kind == kind } }

    // MARK: - Writing back

    /// The card to save. REV is stamped `now`, as web Contacts does on every save.
    func card(now: Date) -> VCard {
        let original = ContactDraft(card: base)
        var card = base
        let is4 = base.version == "4.0"

        // Multi-valued rows: rewrite changed ones in place, drop removed ones, append new.
        var replacements: [Int: DirectoryProperty?] = [:]
        let kept = Dictionary(
            fields.compactMap { field in field.source.map { ($0, field) } }, uniquingKeysWith: { a, _ in a })
        for old in original.fields {
            guard let index = old.source else { continue }
            guard let field = kept[index] else {
                replacements[index] = .some(nil)
                continue
            }
            if field.isEmpty {
                replacements[index] = .some(nil)
            } else if field.type != old.type || field.value != old.value || field.address != old.address {
                replacements[index] = Self.rewrite(base.properties[index], with: field)
            }
        }
        var properties: [DirectoryProperty] = []
        for (index, property) in card.properties.enumerated() {
            if let replacement = replacements[index] {
                if let replacement { properties.append(replacement) }
            } else {
                properties.append(property)
            }
        }
        for field in fields where field.source == nil && !field.isEmpty {
            properties.append(Self.rewrite(DirectoryProperty(name: field.kind.rawValue, value: ""), with: field))
        }
        card.properties = properties

        // Single-valued properties: only touched when they changed.
        if formattedName != original.formattedName || card.property("FN") == nil {
            Self.set(&card, "FN", Self.escape(effectiveFormattedName))
        }
        let nameParts = [family, given, additional, prefix, suffix]
        let originalParts = [original.family, original.given, original.additional, original.prefix, original.suffix]
        if nameParts != originalParts || (card.property("N") == nil && !is4) {
            Self.set(&card, "N", nameParts.map(Self.escape).joined(separator: ";"))
        }
        if nickname != original.nickname {
            let list = nickname.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            Self.set(&card, "NICKNAME", list.isEmpty ? nil : list.map(Self.escape).joined(separator: ","))
        }
        if organization != original.organization || department != original.department {
            let units = [organization] + (department.isEmpty ? [] : department.split(separator: ";").map(String.init))
            let empty = organization.isEmpty && department.isEmpty
            Self.set(&card, "ORG", empty ? nil : units.map(Self.escape).joined(separator: ";"))
        }
        if title != original.title { Self.set(&card, "TITLE", title.isEmpty ? nil : Self.escape(title)) }
        if note != original.note { Self.set(&card, "NOTE", note.isEmpty ? nil : Self.escape(note)) }
        if birthday != original.birthday { Self.set(&card, "BDAY", birthday.isEmpty ? nil : birthday) }
        if anniversary != original.anniversary {
            Self.set(&card, "ANNIVERSARY", anniversary.isEmpty ? nil : anniversary)
        }
        if categories != original.categories {
            // One CATEGORIES line, as web Contacts writes it; several on the way in collapse.
            let unique = categories.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if let index = card.properties.firstIndex(where: { $0.isNamed("CATEGORIES") }) {
                card.properties.removeAll { $0.isNamed("CATEGORIES") }
                if !unique.isEmpty {
                    card.properties.insert(
                        DirectoryProperty(name: "CATEGORIES", value: unique.map(Self.escape).joined(separator: ",")),
                        at: min(index, card.properties.count))
                }
            } else if !unique.isEmpty {
                card.setProperty("CATEGORIES", to: unique.map(Self.escape).joined(separator: ","))
            }
        }
        switch photo {
        case .unchanged: break
        case .removed: card.removeProperties("PHOTO")
        case .set(let data, let subtype):
            let encoded = data.base64EncodedString()
            if is4 {
                Self.set(&card, "PHOTO", "data:image/\(subtype);base64,\(encoded)", parameters: [])
            } else {
                Self.set(
                    &card, "PHOTO", encoded,
                    parameters: [
                        DirectoryParameter(name: "ENCODING", values: ["b"]),
                        DirectoryParameter(name: "TYPE", values: [subtype.uppercased()]),
                    ])
            }
        }
        Self.set(&card, "REV", Self.revision(now), parameters: [])
        return card
    }

    // MARK: - Helpers

    /// Sets, replaces in place keeping the line's group and parameters, or removes (nil).
    private static func set(
        _ card: inout VCard, _ name: String, _ value: String?, parameters: [DirectoryParameter]? = nil
    ) {
        guard let value else {
            card.removeProperties(name)
            return
        }
        if let index = card.properties.firstIndex(where: { $0.isNamed(name) }) {
            card.properties[index].rawValue = value
            if let parameters { card.properties[index].parameters = parameters }
        } else {
            card.addProperty(DirectoryProperty(name: name, parameters: parameters ?? [], value: value))
        }
    }

    /// The property with the row's value and type, every other parameter kept.
    private static func rewrite(_ property: DirectoryProperty, with field: Field) -> DirectoryProperty {
        var property = property
        var parameters = property.parameters.filter { parameter in
            guard parameter.name.caseInsensitiveCompare("TYPE") != .orderedSame else { return false }
            // A bare 2.1 token is a type too; ENCODING/CHARSET go with the old encoded value.
            if parameter.values.isEmpty { return false }
            let name = parameter.name.uppercased()
            return name != "ENCODING" && name != "CHARSET"
        }
        var types = field.type.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 3.0's `TYPE=PREF` is a flag the editor does not show; it stays with the row.
        if property.parameterValues("TYPE").contains(where: { $0.caseInsensitiveCompare("PREF") == .orderedSame }) {
            types.append("pref")
        }
        if !types.isEmpty { parameters.insert(DirectoryParameter(name: "TYPE", values: types), at: 0) }
        property.parameters = parameters
        switch field.kind {
        case .address: property.rawValue = field.address.map(escape).joined(separator: ";")
        case let kind where kind.isURI: property.rawValue = field.value
        default: property.rawValue = escape(field.value)
        }
        return property
    }

    /// The TYPE list as one editable string, `PREF` left out (it is a flag, not a label).
    private static func types(of property: DirectoryProperty) -> String {
        var types = property.parameterValues("TYPE")
        for parameter in property.parameters where parameter.values.isEmpty {
            let name = parameter.name.uppercased()
            if !["ENCODING", "CHARSET", "VALUE", "LANGUAGE", "PREF"].contains(name) { types.append(parameter.name) }
        }
        // Uppercased so `home` and `HOME` are one choice in the type menu.
        return types.filter {
            $0.caseInsensitiveCompare("PREF") != .orderedSame && $0.caseInsensitiveCompare("INTERNET") != .orderedSame
        }
        .map { $0.uppercased() }.joined(separator: ",")
    }

    /// RFC 6350 §3.4 text escaping.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case ",": result += "\\,"
            case ";": result += "\\;"
            case "\n": result += "\\n"
            case "\r": continue
            default: result.append(character)
            }
        }
        return result
    }

    /// `20261004T120000Z`: valid REV in both 3.0 and 4.0.
    static func revision(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return "" }
        let parts = calendar.dateComponents(in: utc, from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return String(format: "%04d", parts.year ?? 0) + two(parts.month) + two(parts.day) + "T"
            + two(parts.hour) + two(parts.minute) + two(parts.second) + "Z"
    }
}
