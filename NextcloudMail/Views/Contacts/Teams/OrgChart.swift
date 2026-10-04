// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore

/// One card as the organisation chart sees it: who it is and whom it reports to.
///
/// The manager is web Contacts' `X-MANAGERSNAME` property — the `UID` parameter names the
/// manager's card in the same address book, the value is the manager's name. It is what web
/// Contacts reads (`Contact.managersName`) and edits, and what the server writes into the
/// system address book from a user's profile "Manager" field. vCard `RELATED` has no
/// manager type, so nothing reads it for this.
nonisolated struct OrgPerson: Sendable, Equatable, Identifiable {
    let id: Int64
    let bookId: Int64
    let uid: String?
    let name: String
    let title: String?
    let organization: String?
    let managerUid: String?
    let managerName: String?

    init(
        id: Int64, bookId: Int64, uid: String?, name: String, title: String? = nil, organization: String? = nil,
        managerUid: String? = nil, managerName: String? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.uid = uid
        self.name = name
        self.title = title
        self.organization = organization
        self.managerUid = managerUid
        self.managerName = managerName
    }

    /// The card's chart facts, parsed from its vCard. Nil for a group card.
    init?(entry: ContactEntry) {
        guard !entry.record.isGroup else { return nil }
        let card = (try? VCardParser.parse(entry.record.vcard))?.first
        let manager = card?.property("X-MANAGERSNAME")
        self.init(
            id: entry.id,
            bookId: entry.record.addressBookId,
            uid: entry.record.uid ?? card?.uid,
            name: entry.displayName(order: .displayName),
            title: card?.title.flatMap { $0.isEmpty ? nil : $0 },
            organization: entry.organization,
            managerUid: manager?.parameterValues("UID").first.flatMap { $0.isEmpty ? nil : $0 },
            managerName: manager.map { $0.decodedValue() }.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// "Title · Organisation", whichever exist.
    var subtitle: String? {
        let parts = [title, organization].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The reporting lines over the mirror, per address book (a manager is looked up in the
/// card's own book, as web Contacts does).
///
/// Who is on the chart: everyone who reports to someone or has someone reporting to them.
/// Two departures from the web chart, both so nobody silently vanishes:
/// - a card whose manager is not in the book still appears, as the top of its own chart,
///   flagged ``isManagerMissing(_:)`` (the web chart drops it);
/// - a reporting cycle (A → B → A) is cut at its alphabetically first member, which becomes a
///   top and is flagged ``isCycleBroken(_:)`` (the web chart recurses forever on one).
nonisolated struct OrgChart: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        let person: OrgPerson
        /// 0 for the top of a chart.
        let depth: Int
        var id: Int64 { person.id }
    }

    private(set) var people: [Int64: OrgPerson] = [:]
    private(set) var managerOf: [Int64: Int64] = [:]
    private(set) var reportsOf: [Int64: [Int64]] = [:]
    private(set) var roots: [Int64] = []
    private(set) var missingManager: Set<Int64> = []
    private(set) var brokenCycles: Set<Int64> = []

    init(_ people: [OrgPerson]) {
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.people = byId
        var byUid: [Int64: [String: Int64]] = [:]
        var byName: [Int64: [String: [Int64]]] = [:]
        for person in people {
            if let uid = person.uid { byUid[person.bookId, default: [:]][uid] = person.id }
            byName[person.bookId, default: [:]][person.name.lowercased(), default: []].append(person.id)
        }

        var manager: [Int64: Int64] = [:]
        var missing: Set<Int64> = []
        for person in people where person.managerUid != nil || person.managerName != nil {
            let resolved =
                person.managerUid.flatMap { byUid[person.bookId]?[$0] }
                // A manager written by name only (another client): accepted when exactly one
                // card in the book has that name.
                ?? person.managerName.flatMap { name in
                    byName[person.bookId]?[name.lowercased()].flatMap { $0.count == 1 ? $0.first : nil }
                }
            if let resolved, resolved != person.id {
                manager[person.id] = resolved
            } else {
                missing.insert(person.id)
            }
        }

        // Cut every cycle once: walk up from each card; meeting a card already on this walk
        // closes a loop, cut at its alphabetically first member.
        var broken: Set<Int64> = []
        var settled: Set<Int64> = []
        for start in manager.keys.sorted() where !settled.contains(start) {
            var path: [Int64] = []
            var onPath: Set<Int64> = []
            var current: Int64? = start
            while let id = current, !settled.contains(id) {
                if onPath.contains(id) {
                    let loop = path[(path.firstIndex(of: id) ?? 0)...]
                    if let cut = loop.min(by: { Self.precedes(byId[$0], byId[$1]) }) {
                        manager[cut] = nil
                        broken.insert(cut)
                    }
                    break
                }
                path.append(id)
                onPath.insert(id)
                current = manager[id]
            }
            settled.formUnion(path)
        }

        var reports: [Int64: [Int64]] = [:]
        for (report, boss) in manager { reports[boss, default: []].append(report) }
        for key in reports.keys {
            reports[key]?.sort { Self.precedes(byId[$0], byId[$1]) }
        }
        let onChart = Set(manager.keys).union(manager.values).union(missing).union(broken)
        managerOf = manager
        reportsOf = reports
        missingManager = missing
        brokenCycles = broken
        roots = onChart.filter { manager[$0] == nil }.sorted { Self.precedes(byId[$0], byId[$1]) }
    }

    var isEmpty: Bool { roots.isEmpty }

    /// Every chart, top first, reports indented under their manager in name order.
    var rows: [Row] {
        var rows: [Row] = []
        var visited: Set<Int64> = []
        func walk(_ id: Int64, depth: Int) {
            guard let person = people[id], visited.insert(id).inserted else { return }
            rows.append(Row(person: person, depth: depth))
            for report in reportsOf[id] ?? [] { walk(report, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        return rows
    }

    /// The managers above a card, nearest first.
    func chain(of id: Int64) -> [OrgPerson] {
        var chain: [OrgPerson] = []
        var seen: Set<Int64> = [id]
        var current = managerOf[id]
        while let next = current, seen.insert(next).inserted, let person = people[next] {
            chain.append(person)
            current = managerOf[next]
        }
        return chain
    }

    func directReports(of id: Int64) -> [OrgPerson] {
        (reportsOf[id] ?? []).compactMap { people[$0] }
    }

    func isManagerMissing(_ id: Int64) -> Bool { missingManager.contains(id) }

    func isCycleBroken(_ id: Int64) -> Bool { brokenCycles.contains(id) }

    /// The rows of the one chart a card sits in: its top and everyone under it.
    func rows(containing id: Int64) -> [Row] {
        var top = id
        var seen: Set<Int64> = [id]
        while let boss = managerOf[top], seen.insert(boss).inserted { top = boss }
        var rows: [Row] = []
        func walk(_ id: Int64, depth: Int) {
            guard let person = people[id] else { return }
            rows.append(Row(person: person, depth: depth))
            for report in reportsOf[id] ?? [] { walk(report, depth: depth + 1) }
        }
        walk(top, depth: 0)
        return rows
    }

    private static func precedes(_ lhs: OrgPerson?, _ rhs: OrgPerson?) -> Bool {
        let order = (lhs?.name ?? "").localizedStandardCompare(rhs?.name ?? "")
        if order != .orderedSame { return order == .orderedAscending }
        return (lhs?.id ?? 0) < (rhs?.id ?? 0)
    }
}
