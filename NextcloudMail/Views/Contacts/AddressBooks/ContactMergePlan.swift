// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// Merging two cards into one, as web Contacts' merge dialog does: one card is kept (its UID,
/// href, book and every property this plan does not model stay as they are), the other is
/// deleted. Each single-value property both cards disagree on is a choice between the two
/// (radio), each multi-value line is kept or dropped (checkbox), and `CATEGORIES` — web
/// Contacts' groups — are combined unless the user says otherwise (ADR-0096).
///
/// Pure: the sheet edits ``singles``/``multis``/``combinesGroups``, ``merged(now:)`` answers
/// the card one `contactPut` writes over the kept contact.
nonisolated struct ContactMergePlan: Equatable, Sendable {
    enum Side: Sendable, Equatable { case kept, other }

    /// One single-value property the cards disagree on. Nil on a side means that card has
    /// none; picking it removes the property.
    struct SingleChoice: Identifiable, Equatable, Sendable {
        let name: String
        let kept: DirectoryProperty?
        let other: DirectoryProperty?
        var pick: Side
        var id: String { name }
    }

    /// One multi-value line of either card. `index` is the line's position in its own card.
    struct MultiValue: Identifiable, Equatable, Sendable {
        let name: String
        let side: Side
        let index: Int
        let property: DirectoryProperty
        var include: Bool
        var id: String { "\(side == .kept ? "k" : "o")\(index)" }
    }

    /// What a card can hold at most once, in the order the sheet lists them.
    static let singleValueNames = [
        "FN", "N", "NICKNAME", "ORG", "TITLE", "ROLE", "BDAY", "ANNIVERSARY", "GENDER", "NOTE", "PHOTO",
    ]
    /// Repeatable lines, each kept or dropped on its own.
    static let multiValueNames = ["EMAIL", "TEL", "ADR", "URL", "IMPP", "X-SOCIALPROFILE", "RELATED"]
    private static let modelled = Set(singleValueNames + multiValueNames + ["CATEGORIES"])

    let kept: VCard
    let other: VCard
    var singles: [SingleChoice]
    var multis: [MultiValue]
    var combinesGroups = true

    init(kept: VCard, other: VCard) {
        self.kept = kept
        self.other = other
        singles = Self.singleValueNames.compactMap { name in
            // Only the other card's lines need a decision: one the kept card alone has stays.
            guard let theirs = other.property(name) else { return nil }
            let mine = kept.property(name)
            if let mine, Self.sameValue(mine, theirs) { return nil }
            // Kept's value wins by default; a gap on the kept card is filled from the other.
            return SingleChoice(name: name, kept: mine, other: theirs, pick: mine == nil ? .other : .kept)
        }
        var rows: [MultiValue] = []
        var seen: Set<String> = []
        for (index, property) in kept.properties.enumerated() {
            guard let name = Self.multiValueNames.first(where: property.isNamed) else { continue }
            seen.insert(Self.dedupeKey(name, property))
            rows.append(MultiValue(name: name, side: .kept, index: index, property: property, include: true))
        }
        for (index, property) in other.properties.enumerated() {
            guard let name = Self.multiValueNames.first(where: property.isNamed) else { continue }
            // The same address or number on both cards is one line, the kept card's.
            guard seen.insert(Self.dedupeKey(name, property)).inserted else { continue }
            rows.append(MultiValue(name: name, side: .other, index: index, property: property, include: true))
        }
        multis = rows
    }

    /// The groups the merged card ends up in.
    var resultingGroups: [String] {
        guard combinesGroups else { return kept.categories }
        var result = kept.categories
        for group in other.categories
        where !result.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) {
            result.append(group)
        }
        return result
    }

    /// The kept card with the choices applied. Lines the plan does not model — and every
    /// modelled line the user left alone — are the kept card's own, byte for byte and in place.
    func merged(now: Date) -> VCard {
        var removed: Set<Int> = []
        var replacements: [Int: [DirectoryProperty]] = [:]
        var appended: [DirectoryProperty] = []
        var importer = GroupImporter(kept: kept, other: other, modelled: Self.modelled)

        for choice in singles where choice.pick == .other {
            let indices = kept.properties.indices.filter { kept.properties[$0].isNamed(choice.name) }
            guard let theirs = choice.other else {
                removed.formUnion(indices)
                continue
            }
            let brought = importer.bring(theirs)
            if let first = indices.first {
                replacements[first] = brought
                removed.formUnion(indices.dropFirst())
            } else {
                appended += brought
            }
        }
        for row in multis {
            switch (row.side, row.include) {
            case (.kept, false): removed.insert(row.index)
            case (.other, true): appended += importer.bring(row.property)
            default: break
            }
        }
        removed.formUnion(orphanedCompanions(removed: removed, replaced: Set(replacements.keys)))

        var card = kept
        card.properties =
            kept.properties.enumerated().flatMap { index, property -> [DirectoryProperty] in
                if let replacement = replacements[index] { return replacement }
                return removed.contains(index) ? [] : [property]
            } + appended

        let groups = resultingGroups
        if groups != kept.categories {
            let value = groups.map(ContactDraft.escape).joined(separator: ",")
            if let first = card.properties.firstIndex(where: { $0.isNamed("CATEGORIES") }) {
                card.properties[first] = DirectoryProperty(name: "CATEGORIES", value: value)
                card.properties = card.properties.enumerated().filter { index, property in
                    index == first || !property.isNamed("CATEGORIES")
                }.map(\.element)
            } else {
                card.addProperty(DirectoryProperty(name: "CATEGORIES", value: value))
            }
        }
        card.setProperty("REV", to: ContactDraft.revision(now))
        return card
    }

    /// A removed (or replaced) kept line's `item1.` companions — an Apple label — go with it
    /// once no remaining modelled line of the kept card shares the group.
    private func orphanedCompanions(removed: Set<Int>, replaced: Set<Int>) -> Set<Int> {
        let gone = removed.union(replaced)
        let groups = Set(gone.compactMap { kept.properties[$0].group?.lowercased() })
        var orphans: Set<Int> = []
        for group in groups {
            let members = kept.properties.indices.filter { kept.properties[$0].group?.lowercased() == group }
            let stillModelled = members.contains { index in
                !gone.contains(index) && Self.modelled.contains(kept.properties[index].name.uppercased())
            }
            if !stillModelled {
                orphans.formUnion(members.filter { !gone.contains($0) })
            }
        }
        return orphans
    }

    /// Whether two single-value lines say the same thing (parameters aside).
    static func sameValue(_ lhs: DirectoryProperty, _ rhs: DirectoryProperty) -> Bool {
        lhs.decodedValue().trimmingCharacters(in: .whitespaces)
            == rhs.decodedValue().trimmingCharacters(in: .whitespaces)
    }

    /// The same address, number or URL spelled differently counts once.
    static func dedupeKey(_ name: String, _ property: DirectoryProperty) -> String {
        let value = property.decodedValue().trimmingCharacters(in: .whitespaces)
        switch name {
        case "TEL":
            let digits = value.filter { $0.isNumber || $0 == "+" }
            return "TEL:" + (digits.isEmpty ? value : digits)
        case "ADR":
            return "ADR:" + property.decodedComponents(separator: ";").joined(separator: ";").lowercased()
        default:
            return name + ":" + value.lowercased()
        }
    }

    /// A one-line rendering of a value for the sheet.
    static func display(_ property: DirectoryProperty) -> String {
        if property.isNamed("PHOTO") { return String(localized: "Picture") }
        if property.isNamed("ADR") || property.isNamed("N") || property.isNamed("ORG") {
            return property.decodedComponents(separator: ";").filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return property.decodedValue()
    }
}

/// Copies lines from the other card with their `itemN.` companions (an Apple `X-ABLabel`),
/// renaming the group when the kept card already uses it so two labels never collide.
nonisolated private struct GroupImporter {
    let other: VCard
    let modelled: Set<String>
    var used: Set<String>
    var renamed: [String: String] = [:]

    init(kept: VCard, other: VCard, modelled: Set<String>) {
        self.other = other
        self.modelled = modelled
        used = Set(kept.properties.compactMap { $0.group?.lowercased() })
    }

    mutating func bring(_ property: DirectoryProperty) -> [DirectoryProperty] {
        guard let group = property.group else { return [property] }
        let key = group.lowercased()
        var lines = [property]
        let target: String
        if let existing = renamed[key] {
            target = existing
        } else {
            target = used.contains(key) ? freshGroup() : group
            renamed[key] = target
            used.insert(target.lowercased())
            // Companions come once, with the first line of their group that is brought.
            lines += other.properties.filter {
                $0.group?.lowercased() == key && !modelled.contains($0.name.uppercased())
            }
        }
        return lines.map { line in
            guard line.group != target else { return line }
            var copy = line
            copy.group = target
            return copy
        }
    }

    private func freshGroup() -> String {
        var number = 1
        while used.contains("item\(number)") { number += 1 }
        return "item\(number)"
    }
}
