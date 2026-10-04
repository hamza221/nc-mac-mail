// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// Date grouping, as a pure function, by the web client's `groupEnvelopesByDate` rules.
///
/// Every date is built from components against a fixed UTC calendar and a fixed `now`, so
/// the suite has no dependency on when it runs or where the machine is.
@Suite("Message list date grouping")
struct MessageListSectionTests {
    private static func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func date(
        _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0
    ) throws -> Date {
        try #require(
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private static func group(_ date: Date, now: Date, _ calendar: Calendar) -> MessageDateGroup {
        MessageDateGroup.of(date, now: now, calendar: calendar)
    }

    @Test("Last hour, Today, Yesterday, Last week, Last month, months of this year, then years")
    func everyBucket() throws {
        let calendar = try Self.calendar()
        // Thursday 24 September 2026, 12:00 UTC.
        let now = try Self.date(calendar, 2026, 9, 24)
        #expect(Self.group(try Self.date(calendar, 2026, 9, 24, hour: 11, minute: 30), now: now, calendar) == .lastHour)
        #expect(Self.group(try Self.date(calendar, 2026, 9, 24, hour: 1), now: now, calendar) == .today)
        #expect(Self.group(try Self.date(calendar, 2026, 9, 23, hour: 1), now: now, calendar) == .yesterday)
        #expect(Self.group(try Self.date(calendar, 2026, 9, 18), now: now, calendar) == .lastWeek)
        #expect(Self.group(try Self.date(calendar, 2026, 8, 30), now: now, calendar) == .lastMonth)
        #expect(Self.group(try Self.date(calendar, 2026, 8, 1), now: now, calendar) == .month(8))
        #expect(Self.group(try Self.date(calendar, 2026, 1, 1), now: now, calendar) == .month(1))
        #expect(Self.group(try Self.date(calendar, 2025, 12, 31), now: now, calendar) == .year(2025))
        #expect(Self.group(try Self.date(calendar, 2019, 5, 5), now: now, calendar) == .year(2019))
    }

    @Test("across New Year, last year's mail is in its year even when it is days old")
    func theYearBoundaryIsTheWebRule() throws {
        let calendar = try Self.calendar()
        // 2 January 2026, midday.
        let now = try Self.date(calendar, 2026, 1, 2)
        // 31 December: still within the last week, and the week wins over the year.
        #expect(Self.group(try Self.date(calendar, 2025, 12, 31), now: now, calendar) == .lastWeek)
        // 20 December: within the last month — "Last month" is a span, not a calendar month.
        #expect(Self.group(try Self.date(calendar, 2025, 12, 20), now: now, calendar) == .lastMonth)
        // 1 December: past a month back and last year, so its year, never "December".
        #expect(Self.group(try Self.date(calendar, 2025, 12, 1), now: now, calendar) == .year(2025))
        // Just after midnight on New Year's Day is plain "Yesterday".
        #expect(Self.group(try Self.date(calendar, 2026, 1, 1, hour: 0, minute: 30), now: now, calendar) == .yesterday)
    }

    @Test("one month back clamps at the end of a short month")
    func lastMonthClampsRatherThanOverflows() throws {
        let calendar = try Self.calendar()
        // 31 March: a month back is 28 February, not JavaScript's 3 March.
        let now = try Self.date(calendar, 2026, 3, 31)
        #expect(Self.group(try Self.date(calendar, 2026, 3, 1), now: now, calendar) == .lastMonth)
        #expect(Self.group(try Self.date(calendar, 2026, 2, 28, hour: 13), now: now, calendar) == .lastMonth)
        #expect(Self.group(try Self.date(calendar, 2026, 2, 27), now: now, calendar) == .month(2))
    }

    @Test("a message dated ahead of this machine's clock reads as the newest bucket")
    func clockSkewDoesNotInventASection() throws {
        let calendar = try Self.calendar()
        let now = try Self.date(calendar, 2026, 9, 24)
        #expect(Self.group(now.addingTimeInterval(90), now: now, calendar) == .lastHour)
        #expect(Self.group(now.addingTimeInterval(86_400 * 3), now: now, calendar) == .lastHour)
    }

    @Test("sections run newest first, drop empty groups, and reverse for oldest first")
    func sectionOrder() async throws {
        let calendar = try Self.calendar()
        let now = try Self.date(calendar, 2026, 9, 24)
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(
            sentAt: [
                Int64(try Self.date(calendar, 2026, 9, 21).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2026, 9, 24, hour: 8).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2026, 2, 3).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2026, 6, 3).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2024, 1, 1).timeIntervalSince1970),
                Int64(try Self.date(calendar, 2023, 1, 1).timeIntervalSince1970),
            ]
        )
        let rows = try await mirror.store.messages(mailboxId: mirror.mailboxId, view: .flat, range: 0..<10)

        let newest = MessageListSection.dateGrouped(rows, order: .newest, now: now, calendar: calendar)
        #expect(newest.map(\.dateGroup) == [.today, .lastWeek, .month(6), .month(2), .year(2024), .year(2023)])
        #expect(newest.map(\.title) == ["Today", "Last week", "June", "February", "2024", "2023"])
        #expect(newest.allSatisfy { $0.rows.count == 1 })

        let oldest = MessageListSection.dateGrouped(rows, order: .oldest, now: now, calendar: calendar)
        #expect(oldest.map(\.dateGroup) == newest.map(\.dateGroup).reversed())
        #expect(Set(oldest.map(\.id)).count == oldest.count)
    }
}
