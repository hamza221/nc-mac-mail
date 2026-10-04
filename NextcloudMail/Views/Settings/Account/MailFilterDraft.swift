// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// One mail filter as the §8.6 editor edits it, read from the mirror's `filtersJSON` and
/// written back as the server's own JSON for `saveFilters`.
///
/// Lossless on purpose: an action type or key the editor does not know (the web's
/// "Redirect to", say) is kept and sent back unchanged, so a filter written by a newer web
/// client survives being edited here. Unknown filter- and test-level keys survive the editor
/// too, but the mirror's `filtersJSON` (WS-21's `FilterJSON`) keeps only the modelled ones.
/// The shape is the server's `FilterBuilder` contract (Mail 5.12): `{name, enable, operator,
/// priority, tests: [{field, operator, values}], actions: [{type, …}]}`.
struct MailFilterDraft: Identifiable, Equatable, Sendable {
    enum Operator: String, CaseIterable, Sendable {
        case all = "allof"
        case any = "anyof"

        var title: String {
            switch self {
            case .all: String(localized: "If all the conditions are met")
            case .any: String(localized: "If any of the conditions are met")
            }
        }
    }

    enum Field: String, CaseIterable, Sendable {
        case subject
        case from
        case to

        var title: String {
            switch self {
            case .subject: String(localized: "Subject")
            case .from: String(localized: "Sender")
            case .to: String(localized: "Recipient")
            }
        }
    }

    enum Match: String, CaseIterable, Sendable {
        case `is`
        case contains
        case matches

        var title: String {
            switch self {
            case .is: String(localized: "is exactly")
            case .contains: String(localized: "contains")
            case .matches: String(localized: "matches")
            }
        }
    }

    struct Condition: Identifiable, Equatable, Sendable {
        let id: UUID
        var field: Field
        var match: Match
        var values: [String]
        /// Keys the editor does not model, sent back as they came.
        var extra: [String: AnyJSON] = [:]

        init(id: UUID = UUID(), field: Field = .subject, match: Match = .is, values: [String] = []) {
            self.id = id
            self.field = field
            self.match = match
            self.values = values
        }
    }

    enum ActionKind: String, CaseIterable, Sendable {
        case addSystemFlag = "addsystemflag"
        case addFlag = "addflag"
        case fileInto = "fileinto"
        case stop

        var title: String {
            switch self {
            case .addSystemFlag: String(localized: "Mark message as")
            case .addFlag: String(localized: "Add flag")
            case .fileInto: String(localized: "Move into folder")
            case .stop: String(localized: "Stop")
            }
        }
    }

    /// The `\Flag` values "Mark message as" offers, as the web's `MailFilterSystemFlag`.
    enum SystemFlag: String, CaseIterable, Sendable {
        case answered = "\\Answered"
        case deleted = "\\Deleted"
        case draft = "\\Draft"
        case flagged = "\\Flagged"
        case seen = "\\Seen"

        var title: String {
            switch self {
            case .answered: String(localized: "Answered")
            case .deleted: String(localized: "Deleted")
            case .draft: String(localized: "Draft")
            case .flagged: String(localized: "Flagged")
            case .seen: String(localized: "Seen")
            }
        }
    }

    /// One action: its `type` and every other key, so unknown types round-trip.
    struct Action: Identifiable, Equatable, Sendable {
        let id: UUID
        var type: String
        var fields: [String: AnyJSON]

        init(id: UUID = UUID(), type: String, fields: [String: AnyJSON] = [:]) {
            self.id = id
            self.type = type
            self.fields = fields
        }

        init(id: UUID = UUID(), kind: ActionKind) {
            self.init(id: id, type: kind.rawValue)
        }

        var kind: ActionKind? { ActionKind(rawValue: type) }

        /// `flag` for both flag kinds; the folder path for `fileinto`.
        var value: String {
            get { fields[kind == .fileInto ? "mailbox" : "flag"]?.stringValue ?? "" }
            set { fields[kind == .fileInto ? "mailbox" : "flag"] = .string(newValue) }
        }

        /// Changing the type drops the old type's value: a folder path is not a flag.
        mutating func change(to newKind: ActionKind) {
            guard newKind != kind else { return }
            type = newKind.rawValue
            fields.removeValue(forKey: "mailbox")
            fields.removeValue(forKey: "flag")
        }

        var isComplete: Bool {
            switch kind {
            case .addFlag, .addSystemFlag, .fileInto: !value.trimmingCharacters(in: .whitespaces).isEmpty
            case .stop, nil: true
            }
        }
    }

    let id: UUID
    /// The id the server's parser gave this filter; sent back, the server drops it.
    var serverId: Int?
    var name: String
    var enable: Bool
    var `operator`: Operator
    var priority: Int
    var conditions: [Condition]
    var actions: [Action]
    var extra: [String: AnyJSON] = [:]

    init(
        id: UUID = UUID(),
        serverId: Int? = nil,
        name: String,
        enable: Bool,
        operator: Operator,
        priority: Int,
        conditions: [Condition],
        actions: [Action]
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.enable = enable
        self.operator = `operator`
        self.priority = priority
        self.conditions = conditions
        self.actions = actions
    }

    // MARK: - Rules (§8.6)

    /// "New filter": enabled, all conditions, Subject is exactly, Move into folder, and a
    /// priority ten above the highest so it runs last.
    static func new(after existing: [MailFilterDraft]) -> MailFilterDraft {
        MailFilterDraft(
            name: String(localized: "New filter"),
            enable: true,
            operator: .all,
            priority: max(0, existing.map(\.priority).max() ?? 0) + 10,
            conditions: [Condition()],
            actions: [Action(kind: .fileInto)]
        )
    }

    /// Adds a Move into folder action, kept before a Stop: Stop ends all processing, so an
    /// action after it would never run.
    mutating func addAction() {
        actions.append(Action(kind: .fileInto))
        keepStopLast()
    }

    mutating func keepStopLast() {
        let stops = actions.filter { $0.type == ActionKind.stop.rawValue }
        actions = actions.filter { $0.type != ActionKind.stop.rawValue } + stops
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !conditions.isEmpty
            && conditions.allSatisfy { !$0.values.isEmpty }
            && !actions.isEmpty
            && actions.allSatisfy(\.isComplete)
    }

    // MARK: - (De)serialisation

    /// The filters in a Sieve row's `filtersJSON`, or nil when the row has none yet (Sieve
    /// off, or the filter route failed and the mirror kept nothing).
    static func parse(_ filtersJSON: String?) -> [MailFilterDraft]? {
        guard
            let filtersJSON,
            case .array(let items)? = try? JSONDecoder().decode(AnyJSON.self, from: Data(filtersJSON.utf8))
        else { return nil }
        return items.compactMap { $0.objectValue.map(MailFilterDraft.init(object:)) }
    }

    init(object: [String: AnyJSON]) {
        var rest = object
        id = UUID()
        serverId = Self.int(rest.removeValue(forKey: "id"))
        name = rest.removeValue(forKey: "name")?.stringValue ?? ""
        enable = Self.bool(rest.removeValue(forKey: "enable"))
        self.operator = Operator(rawValue: rest.removeValue(forKey: "operator")?.stringValue ?? "") ?? .all
        priority = Self.int(rest.removeValue(forKey: "priority")) ?? 0
        if case .array(let tests)? = rest.removeValue(forKey: "tests") {
            conditions = tests.compactMap { $0.objectValue.map(Self.condition) }
        } else {
            conditions = []
        }
        if case .array(let items)? = rest.removeValue(forKey: "actions") {
            actions = items.compactMap { item in
                guard var fields = item.objectValue else { return nil }
                let type = fields.removeValue(forKey: "type")?.stringValue ?? ""
                fields.removeValue(forKey: "id")
                return Action(type: type, fields: fields)
            }
        } else {
            actions = []
        }
        extra = rest
    }

    /// The server's shape. Priority is an integer, as the server's own sanitiser makes it.
    var json: AnyJSON {
        var object = extra
        if let serverId { object["id"] = .int(serverId) }
        object["name"] = .string(name)
        object["enable"] = .bool(enable)
        object["operator"] = .string(self.operator.rawValue)
        object["priority"] = .int(priority)
        object["tests"] = .array(
            conditions.map { condition in
                var test = condition.extra
                test["field"] = .string(condition.field.rawValue)
                test["operator"] = .string(condition.match.rawValue)
                test["values"] = .array(condition.values.map(AnyJSON.string))
                return .object(test)
            })
        object["actions"] = .array(
            actions.map { action in
                var fields = action.fields
                fields["type"] = .string(action.type)
                return .object(fields)
            })
        return .object(object)
    }

    private static func condition(_ object: [String: AnyJSON]) -> Condition {
        var rest = object
        rest.removeValue(forKey: "id")
        let field = Field(rawValue: rest.removeValue(forKey: "field")?.stringValue ?? "") ?? .subject
        let match = Match(rawValue: rest.removeValue(forKey: "operator")?.stringValue ?? "") ?? .is
        var values: [String] = []
        if case .array(let items)? = rest.removeValue(forKey: "values") {
            values = items.compactMap(\.stringValue)
        }
        var condition = Condition(field: field, match: match, values: values)
        condition.extra = rest
        return condition
    }

    private static func int(_ value: AnyJSON?) -> Int? {
        switch value {
        case .int(let number): number
        case .double(let number): Int(number)
        case .string(let text): Int(text)
        default: nil
        }
    }

    private static func bool(_ value: AnyJSON?) -> Bool {
        switch value {
        case .bool(let flag): flag
        case .int(let number): number != 0
        case .string(let text): text == "true" || text == "1"
        default: false
        }
    }

    /// "a, b ,c" → ["a", "b", "c"]: the values field is one comma-separated line.
    static func values(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
