// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One of §4.4's snooze choices, resolved against a clock.
struct SnoozeOption: Identifiable, Equatable, Sendable {
    enum Preset: String, CaseIterable, Sendable {
        case laterToday
        case tomorrow
        case thisWeekend
        case nextWeek
    }

    let preset: Preset
    let date: Date

    var id: String { preset.rawValue }

    /// Unix seconds, which is what `MailOperation.snooze(until:)` takes.
    var until: Int64 { Int64(date.timeIntervalSince1970) }

    var title: String {
        switch preset {
        case .laterToday: String(localized: "Later today")
        case .tomorrow: String(localized: "Tomorrow")
        case .thisWeekend: String(localized: "This weekend")
        case .nextWeek: String(localized: "Next week")
        }
    }

    /// "Later today – 18:00", "Tomorrow – Tue 08:00": the web's labels, with the time in the
    /// user's locale.
    func label(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        if preset != .laterToday {
            style = style.weekday(.abbreviated)
        }
        return "\(title) \u{2013} \(date.formatted(style))"
    }
}

/// The preset rules of the web client's `reminderOptions`, exactly
/// ([ux-spec.md](../../docs/product/ux-spec.md#triage-v2-tags-snooze-quick-actions-pickers-shortcuts-ws-31)):
///
/// - **Later today**, 18:00, only before 17:00.
/// - **Tomorrow**, 08:00, always.
/// - **This weekend**, Saturday 08:00, only Monday to Thursday.
/// - **Next week**, Monday 08:00, every day but Sunday.
///
/// Times land on the hour. The web builds them with moment's `hour()`, which keeps the
/// current minutes; the checklist and this client say 18:00 and 08:00.
///
/// `now` and `calendar` are parameters so the visibility rules are tested on fixed dates
/// rather than on whatever day the suite happens to run.
enum SnoozePresets {
    static func options(now: Date, calendar: Calendar = .current) -> [SnoozeOption] {
        // `weekday` is 1 = Sunday … 7 = Saturday in every Gregorian calendar, whatever the
        // locale's first weekday — the web's `day()` is the same numbering minus one.
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let today = calendar.startOfDay(for: now)

        var options: [SnoozeOption] = []
        if hour < 17, let date = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today) {
            options.append(SnoozeOption(preset: .laterToday, date: date))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
            let date = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        {
            options.append(SnoozeOption(preset: .tomorrow, date: date))
        }
        // Monday (2) to Thursday (5).
        if (2...5).contains(weekday),
            let saturday = calendar.date(byAdding: .day, value: 7 - weekday, to: today),
            let date = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: saturday)
        {
            options.append(SnoozeOption(preset: .thisWeekend, date: date))
        }
        // Not Sunday (1). The next Monday is (9 - weekday) days away: Monday → 7, Saturday → 2.
        if weekday != 1,
            let monday = calendar.date(byAdding: .day, value: 9 - weekday, to: today),
            let date = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: monday)
        {
            options.append(SnoozeOption(preset: .nextWeek, date: date))
        }
        return options
    }
}
