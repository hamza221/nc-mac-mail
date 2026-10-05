// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import NCMailCore

/// The per-property reapply a 412 runs (ADR-0069, ADR-0082).
///
/// The unit is the property *name*: `EMAIL` as a whole, not one address. A card's EMAIL
/// lines have no identity of their own — no id, and position and TYPE both change in other
/// clients — so "the user changed the second address" cannot be matched against a server
/// copy that reordered them. Replacing every line of an edited name with the local ones is
/// the finest rule that is never wrong about what the user meant.
public enum ContactMerge {
    /// Names whose changes are bookkeeping, not user intent. Every editor bumps `REV` and
    /// many rewrite `PRODID`; counting them would turn every concurrent edit into a
    /// same-field conflict.
    static let bookkeeping: Set<String> = ["VERSION", "PRODID", "REV"]

    /// The property names whose lines differ between two cards, upper-cased, in first-seen
    /// order. What a caller puts in `DAVWritePayload.editedProperties` for an edit of
    /// `old` into `new`; for a create (`old` nil) every name of `new`.
    public static func editedProperties(from old: VCard?, to new: VCard) -> [String] {
        let names = orderedNames(new) + (old.map(orderedNames) ?? [])
        var seen = Set<String>()
        return names.filter { name in
            guard seen.insert(name).inserted, !bookkeeping.contains(name) else { return false }
            guard let old else { return true }
            return lines(old, name) != lines(new, name)
        }
    }

    /// The server's card with the local lines of every edited name put back.
    ///
    /// - Parameters:
    ///   - base: the card the local edit started from (the write's `before`), which is how a
    ///     same-field conflict is told apart from a property only the user changed. Nil for a
    ///     create, which cannot conflict field by field.
    /// - Returns: the merged card, and the edited names the server *also* changed — local
    ///   won those, and the caller logs them.
    public static func reapply(
        local: VCard,
        onto server: VCard,
        base: VCard?,
        editedProperties: [String]
    ) -> (merged: VCard, conflicts: [String]) {
        var merged = server
        var conflicts: [String] = []
        var seen = Set<String>()
        for rawName in editedProperties {
            let name = rawName.uppercased()
            guard seen.insert(name).inserted, !bookkeeping.contains(name) else { continue }
            let localProperties = local.properties.filter { $0.isNamed(name) }
            let serverLines = lines(server, name)
            if let base, serverLines != lines(base, name), serverLines != lines(local, name) {
                conflicts.append(name)
            }
            let firstIndex = merged.properties.firstIndex { $0.isNamed(name) }
            merged.properties.removeAll { $0.isNamed(name) }
            let insertAt = min(firstIndex ?? merged.properties.count, merged.properties.count)
            merged.properties.insert(contentsOf: localProperties, at: insertAt)
        }
        return (merged, conflicts)
    }

    private static func orderedNames(_ card: VCard) -> [String] {
        card.properties.map { $0.name.uppercased() }
    }

    /// A name's lines as a comparable value: order matters (it is the user's order), group
    /// labels matter (`item1.EMAIL` pairs with `item1.X-ABLabel`).
    static func lines(_ card: VCard, _ name: String) -> [String] {
        card.properties.filter { $0.isNamed(name) }.map(\.serializedLine)
    }
}
