// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import Testing

@testable import NextcloudMail

/// WS-36's merge matrix: which properties become choices, what each choice writes, and what
/// is never touched.
@Suite("Merge two contacts")
struct ContactMergePlanTests {
    private static let now = Date(timeIntervalSince1970: 1_791_115_200)  // 2026-10-04T12:00:00Z

    private func card(_ lines: [String]) throws -> VCard {
        let text = (["BEGIN:VCARD", "VERSION:3.0"] + lines + ["END:VCARD", ""]).joined(separator: "\r\n")
        return try #require(try VCardParser.parse(text).first)
    }

    private var kept: VCard {
        get throws {
            try card([
                "UID:kept-uid",
                "FN:Rory Gilmore",
                "N:Gilmore;Rory;;;",
                "NOTE:Kept note",
                "item1.EMAIL;TYPE=INTERNET:Rory@Example.org",
                "item1.X-ABLabel:_$!<Work>!$_",
                "TEL;TYPE=CELL:+1 (555) 0100",
                "X-KEPT-UNKNOWN;X-PARAM=\"a, b\":opaque\\;value",
                "CATEGORIES:Yale,Friends",
            ])
        }
    }

    private var other: VCard {
        get throws {
            try card([
                "UID:other-uid",
                "FN:Lorelai Rory Gilmore",
                "N:Gilmore;Rory;;;",
                "TITLE:Reporter",
                "item1.EMAIL;TYPE=INTERNET:rory@example.org",
                "item2.EMAIL;TYPE=HOME:rory@home.example",
                "item2.X-ABLabel:Home-ish",
                "TEL:+15550100",
                "TEL;TYPE=WORK:+1 555 0199",
                "CATEGORIES:friends,Chilton",
                "X-OTHER-UNKNOWN:dropped",
            ])
        }
    }

    @Test func singlesAreOnlyTheDisagreementsAndGapsWithKeptWinningByDefault() throws {
        let plan = ContactMergePlan(kept: try kept, other: try other)
        // N is equal, NOTE only on the kept card: neither is a choice.
        #expect(plan.singles.map(\.name) == ["FN", "TITLE"])
        #expect(plan.singles.first { $0.name == "FN" }?.pick == .kept)
        // A gap on the kept card is filled from the other by default.
        #expect(plan.singles.first { $0.name == "TITLE" }?.pick == .other)
    }

    @Test func multisDedupeSpellingsAndKeepEverythingByDefault() throws {
        let plan = ContactMergePlan(kept: try kept, other: try other)
        let values = plan.multis.map { "\($0.side == .kept ? "k" : "o"):\($0.name):\($0.property.decodedValue())" }
        // The address in other case and the number in other punctuation are one line each.
        #expect(
            values == [
                "k:EMAIL:Rory@Example.org", "k:TEL:+1 (555) 0100", "o:EMAIL:rory@home.example", "o:TEL:+1 555 0199",
            ])
        #expect(plan.multis.allSatisfy { $0.include })
    }

    @Test func defaultMergeKeepsUnknownLinesAndBringsTheRestIn() throws {
        let plan = ContactMergePlan(kept: try kept, other: try other)
        let merged = plan.merged(now: Self.now)
        let lines = merged.properties.map(\.serializedLine)
        #expect(merged.uid == "kept-uid")
        #expect(merged.formattedName == "Rory Gilmore")
        #expect(merged.title == "Reporter")
        #expect(merged.note == "Kept note")
        #expect(lines.contains("X-KEPT-UNKNOWN;X-PARAM=\"a, b\":opaque\\;value"))
        // The other card's unknown properties are not modelled and do not come across.
        #expect(!lines.contains { $0.hasPrefix("X-OTHER-UNKNOWN") })
        #expect(merged.emails.map(\.value) == ["Rory@Example.org", "rory@home.example"])
        #expect(merged.phones.map(\.value) == ["+1 (555) 0100", "+1 555 0199"])
        #expect(merged.rev == "20261004T120000Z")
    }

    @Test func aBroughtLineKeepsItsLabelUnderAFreeGroup() throws {
        let plan = ContactMergePlan(kept: try kept, other: try other)
        let merged = plan.merged(now: Self.now)
        // item1 is the kept card's; the other card's item2 is free and stays item2.
        let home = try #require(
            merged.properties.first { $0.isNamed("EMAIL") && $0.decodedValue() == "rory@home.example" })
        #expect(home.group == "item2")
        #expect(
            merged.properties.contains { $0.group == "item2" && $0.isNamed("X-ABLabel") && $0.rawValue == "Home-ish" })
        #expect(merged.properties.count { $0.isNamed("X-ABLabel") } == 2)
    }

    @Test func aCollidingGroupIsRenamed() throws {
        let keptCard = try card(["UID:k", "FN:A", "item1.TEL:1", "item1.X-ABLabel:One", "item2.URL:https://a.example"])
        let otherCard = try card(["UID:o", "FN:A", "item1.EMAIL:x@example.org", "item1.X-ABLabel:Mine"])
        let merged = ContactMergePlan(kept: keptCard, other: otherCard).merged(now: Self.now)
        let email = try #require(merged.properties.first { $0.isNamed("EMAIL") })
        #expect(email.group == "item3")
        #expect(merged.properties.contains { $0.group == "item3" && $0.rawValue == "Mine" })
        #expect(merged.properties.contains { $0.group == "item1" && $0.rawValue == "One" })
    }

    @Test func choosingTheOtherSingleReplacesInPlace() throws {
        var plan = ContactMergePlan(kept: try kept, other: try other)
        let index = try #require(plan.singles.firstIndex { $0.name == "FN" })
        plan.singles[index].pick = .other
        let merged = plan.merged(now: Self.now)
        #expect(merged.formattedName == "Lorelai Rory Gilmore")
        let keptPosition = try kept.properties.firstIndex { $0.isNamed("FN") }
        #expect(merged.properties.firstIndex { $0.isNamed("FN") } == keptPosition)
        #expect(merged.properties.count { $0.isNamed("FN") } == 1)
    }

    @Test func choosingTheKeptGapDropsTheOthersValue() throws {
        var plan = ContactMergePlan(kept: try kept, other: try other)
        let index = try #require(plan.singles.firstIndex { $0.name == "TITLE" })
        plan.singles[index].pick = .kept
        #expect(plan.merged(now: Self.now).title == nil)
    }

    @Test func uncheckingAKeptLineRemovesItAndItsOrphanedLabel() throws {
        var plan = ContactMergePlan(kept: try kept, other: try other)
        let index = try #require(plan.multis.firstIndex { $0.side == .kept && $0.name == "EMAIL" })
        plan.multis[index].include = false
        let merged = plan.merged(now: Self.now)
        #expect(!merged.properties.contains { $0.group == "item1" })
        #expect(merged.emails.map(\.value) == ["rory@home.example"])
    }

    @Test func uncheckingAnOtherLineLeavesItOut() throws {
        var plan = ContactMergePlan(kept: try kept, other: try other)
        for index in plan.multis.indices where plan.multis[index].side == .other {
            plan.multis[index].include = false
        }
        let merged = plan.merged(now: Self.now)
        #expect(merged.emails.map(\.value) == ["Rory@Example.org"])
        #expect(merged.phones.count == 1)
        #expect(!merged.properties.contains { $0.group == "item2" })
    }

    @Test func groupsAreCombinedByDefaultCaseInsensitively() throws {
        var plan = ContactMergePlan(kept: try kept, other: try other)
        #expect(plan.merged(now: Self.now).categories == ["Yale", "Friends", "Chilton"])
        plan.combinesGroups = false
        #expect(plan.merged(now: Self.now).categories == ["Yale", "Friends"])
        // Unchanged groups leave the kept line as written.
        #expect(plan.merged(now: Self.now).properties.contains { $0.serializedLine == "CATEGORIES:Yale,Friends" })
    }

    @Test func groupsComeFromTheOtherCardWhenTheKeptHasNone() throws {
        let keptCard = try card(["UID:k", "FN:A"])
        let otherCard = try card(["UID:o", "FN:A", "CATEGORIES:Team\\, A,B"])
        let merged = ContactMergePlan(kept: keptCard, other: otherCard).merged(now: Self.now)
        #expect(merged.categories == ["Team, A", "B"])
    }

    @Test func identicalCardsHaveNothingToChoose() throws {
        let plan = ContactMergePlan(kept: try kept, other: try kept)
        #expect(plan.singles.isEmpty)
        #expect(plan.multis.allSatisfy { $0.side == .kept })
        let merged = plan.merged(now: Self.now)
        // Only REV moves.
        #expect(
            merged.properties.filter { !$0.isNamed("REV") }.map(\.serializedLine)
                == (try kept).properties.map(\.serializedLine))
    }
}
