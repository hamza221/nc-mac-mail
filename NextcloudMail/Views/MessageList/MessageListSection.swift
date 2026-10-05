// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// The web client's date buckets (`groupEnvelopesByDate`), so a mailbox reads the same in
/// both clients: Last hour, Today, Yesterday, Last week, Last month, then this year's
/// earlier months by name, then earlier years.
///
/// The year rule is the web's and it is deliberate parity, not an oversight: anything from a
/// previous year goes in its year's bucket even when it is only days old, so on 2 January
/// December's mail reads "2025" rather than "Last month" (ux-spec.md, WS-29).
enum MessageDateGroup: Hashable, Sendable {
    case lastHour
    case today
    case yesterday
    case lastWeek
    case lastMonth
    /// A month of the current year, 1–12.
    case month(Int)
    case year(Int)

    func title(calendar: Calendar = .autoupdatingCurrent) -> String {
        switch self {
        case .lastHour: String(localized: "Last hour")
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .lastWeek: String(localized: "Last week")
        case .lastMonth: String(localized: "Last month")
        case .month(let month):
            calendar.standaloneMonthSymbols.indices.contains(month - 1)
                ? calendar.standaloneMonthSymbols[month - 1] : String(month)
        // Not `formatted()`: a year is a name here, and "2,025" is not one.
        case .year(let year): String(year)
        }
    }

    /// Newest-first position. Months and years count down, so a larger key is older.
    var rank: (Int, Int) {
        switch self {
        case .lastHour: (0, 0)
        case .today: (1, 0)
        case .yesterday: (2, 0)
        case .lastWeek: (3, 0)
        case .lastMonth: (4, 0)
        case .month(let month): (5, -month)
        case .year(let year): (6, -year)
        }
    }

    /// Which bucket `date` falls in, by the web client's thresholds.
    ///
    /// A future date (server clock skew) is "Last hour": it is the newest thing there is,
    /// and a bucket holding one message from the future is a bug report.
    static func of(_ date: Date, now: Date, calendar: Calendar) -> MessageDateGroup {
        if date >= now.addingTimeInterval(-3_600) { return .lastHour }
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
            date >= startOfYesterday
        {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo { return .lastWeek }
        // Calendar clamps 31 March minus a month to 28 February; JavaScript's `setMonth`
        // overflows to 3 March. The clamp is the answer a person would give.
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date >= monthAgo { return .lastMonth }
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            return .month(calendar.component(.month, from: date))
        }
        return .year(year)
    }
}

/// Which part of a list a section belongs to: the whole list, or one of the sections Priority
/// inbox and "favorites on top" split a list into.
enum MessageListBucket: String, Hashable, Sendable {
    case all
    case favorites
    case followUp
    case important
    case other

    /// Nil for ``all``, whose rows are headed by their date groups instead.
    var title: String? {
        switch self {
        case .all: nil
        case .favorites: String(localized: "Favorites")
        case .followUp: String(localized: "Follow up")
        case .important: String(localized: "Important")
        case .other: String(localized: "Other")
        }
    }
}

/// One `Section` of the list.
struct MessageListSection: Identifiable, Equatable {
    let bucket: MessageListBucket
    /// Set for a date-grouped part of a list, nil for a bucket shown whole.
    let dateGroup: MessageDateGroup?
    let rows: [MessageRow]
    let title: String?

    var id: String {
        guard let dateGroup else { return bucket.rawValue }
        return "\(bucket.rawValue).\(dateGroup)"
    }

    init(
        bucket: MessageListBucket, dateGroup: MessageDateGroup? = nil, rows: [MessageRow],
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.bucket = bucket
        self.dateGroup = dateGroup
        self.rows = rows
        self.title = dateGroup?.title(calendar: calendar) ?? bucket.title
    }

    /// Splits one bucket's rows into date groups, in the order `order` reads them, dropping
    /// empty groups.
    ///
    /// Rows keep the order the query gave them inside each group; only the groups are put in
    /// order, which stays correct whichever way the query sorted.
    ///
    /// - Parameters:
    ///   - now: Injected so tests do not depend on the wall clock.
    ///   - calendar: Injected for the same reason, and because "today" depends on the zone.
    static func dateGrouped(
        _ rows: [MessageRow],
        bucket: MessageListBucket = .all,
        order: MessageSortOrder = .newest,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MessageListSection] {
        var buckets: [MessageDateGroup: [MessageRow]] = [:]
        for row in rows {
            let sentAt = Date(timeIntervalSince1970: TimeInterval(row.sentAt))
            buckets[MessageDateGroup.of(sentAt, now: now, calendar: calendar), default: []].append(row)
        }
        let groups = buckets.keys.sorted { $0.rank < $1.rank }
        return (order == .newest ? groups : groups.reversed()).compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return MessageListSection(bucket: bucket, dateGroup: group, rows: rows, calendar: calendar)
        }
    }
}
