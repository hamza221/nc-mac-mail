// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// The tag modal's rules, as the web's `TagModal.vue`, `tags.js` and `util/tag.js` state them
/// (§4.8). Pure, so the order and the validation are tested without a view.
enum TagRules {
    /// Important. Shown as its own toggle everywhere, never as a tag.
    static let importantLabel = "$label1"
    /// The follow-up reminder's keyword, displayed as "Follow up".
    static let followUpLabel = "$follow_up"
    /// The server's default tags besides Important: Work, Personal, To Do, Later.
    static let defaultLabels: Set<String> = ["$label2", "$label3", "$label4", "$label5"]

    /// `components/tags.js`'s `hiddenTags`, matched against the lowercased display name.
    static let hiddenNames: Set<String> = [
        "forwarded", "hasattachment", "has_cal", "has cal", "hasnoattachment", "notjunk",
        "loadremoteimages", "unsubscribe newsletter",
    ]

    static func isDefault(_ tag: TagRecord) -> Bool { defaultLabels.contains(tag.imapLabel) }

    static func isListed(_ tag: TagRecord) -> Bool {
        tag.imapLabel != importantLabel && !hiddenNames.contains(tag.displayName.lowercased())
    }

    static func displayName(of tag: TagRecord) -> String {
        if tag.imapLabel == followUpLabel, tag.displayName == "Follow up" {
            return String(localized: "Follow up")
        }
        return tag.displayName
    }

    /// Defaults first, then the tags every envelope already has, then alphabetical.
    ///
    /// The web sorts defaults *descending* by name (its comparator returns 1 when `a < b`),
    /// which puts "Work, To Do, Personal, Later" in that order; kept, since people use both.
    static func ordered(_ tags: [TagRecord], setOnAll: Set<String>) -> [TagRecord] {
        tags.filter(isListed).sorted { a, b in
            let aDefault = isDefault(a)
            let bDefault = isDefault(b)
            if aDefault != bDefault { return aDefault }
            if aDefault { return a.displayName > b.displayName }
            let aSet = setOnAll.contains(a.imapLabel)
            let bSet = setOnAll.contains(b.imapLabel)
            if aSet != bSet { return aSet }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    enum ValidationError: Equatable, Sendable {
        case empty
        case hidden
        case duplicate

        var message: String {
            switch self {
            case .empty: String(localized: "Tag name cannot be empty")
            case .hidden: String(localized: "Tag name is a hidden system tag")
            case .duplicate: String(localized: "Tag already exists")
            }
        }
    }

    /// `validateTag`: nil when the name is fine. `editing` is the tag being renamed, which may
    /// keep its own name.
    static func validate(_ name: String, editing: TagRecord? = nil, among tags: [TagRecord]) -> ValidationError? {
        let testable = name.trimmingCharacters(in: .whitespaces).lowercased()
        if testable.isEmpty { return .empty }
        if hiddenNames.contains(testable) { return .hidden }
        if tags.contains(where: { $0.id != editing?.id && $0.displayName.lowercased() == testable }) {
            return .duplicate
        }
        return nil
    }

    /// `#rrggbb`, uniformly random, as the web's `randomColor()`.
    static func randomColor<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let value = UInt32.random(in: 0..<(1 << 24), using: &generator)
        return "#" + String(format: "%06x", value)
    }

    static func randomColor() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomColor(using: &generator)
    }
}
