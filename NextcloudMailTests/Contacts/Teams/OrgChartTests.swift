// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import Testing

@testable import NextcloudMail

/// The organisation chart over `X-MANAGERSNAME`: levels, missing managers, cycles.
@Suite("Organisation chart")
struct OrgChartTests {
    private static func person(
        _ id: Int64, _ name: String, uid: String? = nil, manager: String? = nil, managerName: String? = nil,
        book: Int64 = 1
    ) -> OrgPerson {
        OrgPerson(
            id: id, bookId: book, uid: uid ?? name.lowercased(), name: name, managerUid: manager,
            managerName: managerName)
    }

    private func layout(_ chart: OrgChart) -> [String] {
        chart.rows.map { String(repeating: "  ", count: $0.depth) + $0.person.name }
    }

    @Test func levelsIndentUnderTheirManagerInNameOrder() {
        let chart = OrgChart([
            Self.person(1, "Ceo"),
            Self.person(2, "Zed", manager: "ceo"),
            Self.person(3, "Amy", manager: "ceo"),
            Self.person(4, "Bob", manager: "amy"),
            Self.person(5, "Loner"),
        ])
        #expect(layout(chart) == ["Ceo", "  Amy", "    Bob", "  Zed"])
        #expect(chart.chain(of: 4).map(\.name) == ["Amy", "Ceo"])
        #expect(chart.directReports(of: 1).map(\.name) == ["Amy", "Zed"])
        // Someone with no manager and no reports is on no chart, as on the web.
        #expect(chart.people[5] != nil && !chart.rows.contains { $0.person.id == 5 })
    }

    @Test func aMissingManagerMakesItsReportATopNotAGap() {
        let chart = OrgChart([
            Self.person(1, "Amy", manager: "gone", managerName: "Gone Person"),
            Self.person(2, "Bob", manager: "amy"),
        ])
        #expect(layout(chart) == ["Amy", "  Bob"])
        #expect(chart.isManagerMissing(1))
        #expect(!chart.isManagerMissing(2))
        #expect(chart.chain(of: 1).isEmpty)
    }

    @Test func aMissingManagerWithNoReportsStillShows() {
        let chart = OrgChart([Self.person(1, "Amy", manager: "gone")])
        #expect(layout(chart) == ["Amy"])
        #expect(chart.isManagerMissing(1))
    }

    @Test func aTwoPersonCycleIsCutAtTheFirstName() {
        let chart = OrgChart([
            Self.person(1, "Bob", manager: "amy"),
            Self.person(2, "Amy", manager: "bob"),
            Self.person(3, "Cat", manager: "bob"),
        ])
        #expect(layout(chart) == ["Amy", "  Bob", "    Cat"])
        #expect(chart.isCycleBroken(2))
        #expect(!chart.isCycleBroken(1))
        #expect(chart.chain(of: 3).map(\.name) == ["Bob", "Amy"])
    }

    @Test func aLongerCycleBelowARootKeepsTheRootAndCutsTheLoop() {
        // Dan → Eve → Fay → Dan, and Gus reports into the loop.
        let chart = OrgChart([
            Self.person(1, "Dan", manager: "fay"),
            Self.person(2, "Eve", manager: "dan"),
            Self.person(3, "Fay", manager: "eve"),
            Self.person(4, "Gus", manager: "eve"),
        ])
        #expect(chart.brokenCycles == [1])
        #expect(layout(chart) == ["Dan", "  Eve", "    Fay", "    Gus"])
        // Every person appears exactly once: the walk cannot loop.
        #expect(chart.rows.count == 4)
    }

    @Test func aSelfManagerIsAMissingManager() {
        let chart = OrgChart([Self.person(1, "Amy", manager: "amy"), Self.person(2, "Bob", manager: "amy")])
        #expect(chart.isManagerMissing(1))
        #expect(layout(chart) == ["Amy", "  Bob"])
    }

    @Test func managersResolveInsideTheCardsOwnBookOnly() {
        let chart = OrgChart([
            Self.person(1, "Boss", book: 1),
            Self.person(2, "Amy", manager: "boss", book: 2),
        ])
        #expect(chart.isManagerMissing(2))
        #expect(chart.chain(of: 2).isEmpty)
    }

    @Test func aNameOnlyManagerResolvesWhenTheNameIsUnique() {
        let unique = OrgChart([
            Self.person(1, "Big Boss", uid: "x1"),
            Self.person(2, "Amy", managerName: "big boss"),
        ])
        #expect(unique.chain(of: 2).map(\.name) == ["Big Boss"])

        let ambiguous = OrgChart([
            Self.person(1, "Big Boss", uid: "x1"),
            Self.person(3, "Big Boss", uid: "x2"),
            Self.person(2, "Amy", managerName: "Big Boss"),
        ])
        #expect(ambiguous.isManagerMissing(2))
    }

    @Test func rowsContainingAPersonAreTheirWholeChart() {
        let chart = OrgChart([
            Self.person(1, "Ceo"),
            Self.person(2, "Amy", manager: "ceo"),
            Self.person(3, "Other Top"),
            Self.person(4, "Zoe", manager: "other top"),
        ])
        #expect(chart.rows(containing: 2).map(\.person.name) == ["Ceo", "Amy"])
        #expect(chart.rows(containing: 3).map(\.person.name) == ["Other Top", "Zoe"])
    }

    @Test func theManagerIsReadFromTheCardsXManagersName() throws {
        let vcard =
            [
                "BEGIN:VCARD", "VERSION:3.0", "UID:alice", "FN:Alice", "TITLE:Engineer", "ORG:Nextcloud",
                "X-MANAGERSNAME;UID=admin:Admin Person", "END:VCARD",
            ].joined(separator: "\r\n") + "\r\n"
        let entry = try #require(
            ContactEntry(
                record: ContactRecord(
                    id: 7, addressBookId: 3, href: "/alice.vcf", uid: "alice", vcard: vcard, displayName: "Alice",
                    syncedAt: 0)))
        let person = try #require(OrgPerson(entry: entry))
        #expect(person.managerUid == "admin")
        #expect(person.managerName == "Admin Person")
        #expect(person.subtitle == "Engineer · Nextcloud")
    }

    @Test func twoThousandCardsParseAndBuildQuickly() throws {
        let entries = (1...2000).compactMap { index -> ContactEntry? in
            let manager = index == 1 ? "" : "X-MANAGERSNAME;UID=u\(index / 10):Boss\r\n"
            let vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:u\(index)\r\nFN:Person \(index)\r\n\(manager)END:VCARD\r\n"
            return ContactEntry(
                record: ContactRecord(
                    id: Int64(index), addressBookId: 1, href: "/\(index).vcf", uid: "u\(index)", vcard: vcard,
                    syncedAt: 0))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let chart = OrgChart(entries.compactMap(OrgPerson.init(entry:)))
        let elapsed = clock.now - start
        FileHandle.standardError.write(Data("org chart: 2000 cards parsed and built in \(elapsed)\n".utf8))
        #expect(chart.rows.count == 2000)
        #expect(elapsed < .seconds(2))
    }
}
