// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// The four buckets a message list is read in.
///
/// Not a formatted date: people scan a mailbox by recency, and "Tuesday" is a fact about a
/// calendar while "This week" is a fact about how far back they are looking.
enum MessageDateGroup: Int, CaseIterable, Sendable {
    case today
    case yesterday
    case thisWeek
    case earlier

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .thisWeek: String(localized: "This week")
        case .earlier: String(localized: "Earlier")
        }
    }
}

/// One `Section` of the list: a date bucket and the rows in it.
struct MessageListSection: Identifiable, Equatable {
    let group: MessageDateGroup
    let rows: [MessageRow]

    var id: Int { group.rawValue }
    var title: String { group.title }

    /// Buckets `rows`, keeping ``MessageDateGroup``'s order and dropping empty buckets.
    ///
    /// The rows arrive newest first, so bucketing and then emitting in case order gives the
    /// same result as a single pass over consecutive runs — and stays correct if the sort
    /// ever reverses, which a run-based pass would not.
    ///
    /// - Parameters:
    ///   - now: Injected rather than read here, so the tests do not depend on the wall clock.
    ///   - calendar: Injected for the same reason, and because "this week" starts on a
    ///     different day depending on the locale.
    static func sections(
        for rows: [MessageRow],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MessageListSection] {
        var buckets: [MessageDateGroup: [MessageRow]] = [:]
        for row in rows {
            let sentAt = Date(timeIntervalSince1970: TimeInterval(row.sentAt))
            buckets[group(of: sentAt, now: now, calendar: calendar), default: []].append(row)
        }
        return MessageDateGroup.allCases.compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return MessageListSection(group: group, rows: rows)
        }
    }

    /// Which bucket `date` falls in.
    ///
    /// A date in the future is "today". Clock skew between a server and this machine puts a
    /// message a few seconds ahead, and a "Later" section that holds one message is a bug
    /// report rather than a feature.
    static func group(of date: Date, now: Date, calendar: Calendar) -> MessageDateGroup {
        if date > now || calendar.isDate(date, inSameDayAs: now) { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return .earlier }
        if calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }
}
