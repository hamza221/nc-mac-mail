// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// Date grouping, as a pure function.
///
/// Every date here is built from components against a fixed calendar and a fixed `now`, so
/// the suite has no dependency on when it runs or on where the machine is.
@Suite("Message list date grouping")
struct MessageListSectionTests {
    /// Thursday 24 September 2026, midday, UTC.
    private static func calendar(firstWeekday: Int) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func date(
        _ calendar: Calendar,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12
    ) throws -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour)
        return try #require(calendar.date(from: components))
    }

    @Test("the four buckets, against a Monday-first week")
    func bucketsWithAMondayFirstWeek() throws {
        let calendar = try Self.calendar(firstWeekday: 2)
        let now = try Self.date(calendar, 2026, 9, 24)

        let cases: [(Date, MessageDateGroup)] = [
            (try Self.date(calendar, 2026, 9, 24, hour: 1), .today),
            (try Self.date(calendar, 2026, 9, 24, hour: 23), .today),
            (try Self.date(calendar, 2026, 9, 23), .yesterday),
            (try Self.date(calendar, 2026, 9, 22), .thisWeek),
            (try Self.date(calendar, 2026, 9, 21), .thisWeek),
            // Sunday, which belongs to the previous week when the week starts on a Monday.
            (try Self.date(calendar, 2026, 9, 20), .earlier),
            (try Self.date(calendar, 2025, 9, 24), .earlier),
        ]

        for (date, expected) in cases {
            #expect(
                MessageListSection.group(of: date, now: now, calendar: calendar) == expected,
                "\(date) should be \(expected)"
            )
        }
    }

    @Test("where the week starts moves the boundary, and nothing else")
    func theWeekBoundaryFollowsTheCalendar() throws {
        let mondayFirst = try Self.calendar(firstWeekday: 2)
        let sundayFirst = try Self.calendar(firstWeekday: 1)
        let now = try Self.date(mondayFirst, 2026, 9, 24)
        let sunday = try Self.date(mondayFirst, 2026, 9, 20)

        #expect(MessageListSection.group(of: sunday, now: now, calendar: mondayFirst) == .earlier)
        #expect(MessageListSection.group(of: sunday, now: now, calendar: sundayFirst) == .thisWeek)
    }

    @Test("a message dated ahead of this machine's clock reads as today")
    func clockSkewDoesNotInventASection() throws {
        let calendar = try Self.calendar(firstWeekday: 2)
        let now = try Self.date(calendar, 2026, 9, 24)
        let skewed = now.addingTimeInterval(45)
        let tomorrow = try Self.date(calendar, 2026, 9, 25)

        #expect(MessageListSection.group(of: skewed, now: now, calendar: calendar) == .today)
        #expect(MessageListSection.group(of: tomorrow, now: now, calendar: calendar) == .today)
    }

    @Test("an empty bucket draws no section header")
    func emptyBucketsAreDropped() async throws {
        let calendar = try Self.calendar(firstWeekday: 2)
        let now = try Self.date(calendar, 2026, 9, 24)
        let mirror = try await MessageListMirror.seed()
        // Today and last year, with nothing in between.
        try await mirror.addMessages(
            sentAt: [
                Int64(try Self.date(calendar, 2026, 9, 24, hour: 9).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2025, 9, 24).timeIntervalSince1970),
            ]
        )

        let rows = try await mirror.store.messages(mailboxId: mirror.mailboxId, view: .flat, range: 0..<10)
        let sections = MessageListSection.sections(for: rows, now: now, calendar: calendar)

        #expect(sections.map(\.group) == [.today, .earlier])
        #expect(sections.map { $0.rows.count } == [1, 1])
        #expect(sections.map(\.id) == [MessageDateGroup.today.rawValue, MessageDateGroup.earlier.rawValue])
    }

    @Test("sections come out newest first whatever order the rows arrive in")
    func sectionOrderFollowsTheEnumeration() async throws {
        let calendar = try Self.calendar(firstWeekday: 2)
        let now = try Self.date(calendar, 2026, 9, 24)
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(
            sentAt: [
                Int64(try Self.date(calendar, 2026, 9, 21).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2026, 9, 24, hour: 8).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2026, 9, 23).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2024, 1, 1).timeIntervalSince1970),
            ]
        )

        let rows = try await mirror.store.messages(mailboxId: mirror.mailboxId, view: .flat, range: 0..<10)
        let sections = MessageListSection.sections(for: rows, now: now, calendar: calendar)
        #expect(sections.map(\.group) == [.today, .yesterday, .thisWeek, .earlier])
    }
}
