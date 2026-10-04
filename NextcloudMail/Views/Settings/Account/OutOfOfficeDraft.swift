// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync

/// The §8.4 autoresponder form: what the Sieve row holds, the web's date rules, and the
/// command a save runs.
struct OutOfOfficeDraft: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case off
        case on
        case followSystem

        var title: String {
            switch self {
            case .off: String(localized: "Autoresponder off")
            case .on: String(localized: "Autoresponder on")
            case .followSystem: String(localized: "Autoresponder follows system settings")
            }
        }
    }

    var mode: Mode = .off
    var firstDay: Date
    var lastDay: Date?
    var subject = ""
    var message = ""

    var hasLastDay: Bool { lastDay != nil }

    init(firstDay: Date) {
        self.firstDay = firstDay
    }

    /// The form as the mirror has it. `start`/`end` are the server's ISO dates; the end is
    /// stored as the instant after the last day (the web adds 24 h), so it is read back as
    /// the day before.
    init(account: AccountRecord, sieve: SieveStateRecord?, now: Date, calendar: Calendar = .current) {
        self.init(firstDay: calendar.startOfDay(for: now))
        let state = Self.state(sieve?.outOfOfficeJSON)
        if account.outOfOfficeFollowsSystem {
            mode = .followSystem
        } else {
            mode = state?.enabled == true ? .on : .off
        }
        guard let state else { return }
        if state.enabled, let start = state.start.flatMap(Self.date) {
            firstDay = calendar.startOfDay(for: start)
        }
        if state.enabled, let end = state.end.flatMap(Self.date) {
            lastDay = calendar.startOfDay(for: end.addingTimeInterval(-23 * 3_600))
        }
        subject = state.subject ?? ""
        message = state.message ?? ""
    }

    /// Turning "Last day" on starts it six days after the first, as the web does.
    mutating func setHasLastDay(_ on: Bool, calendar: Calendar = .current) {
        lastDay = on ? calendar.date(byAdding: .day, value: 6, to: firstDay) : nil
    }

    /// Moving the first day keeps the gap to the last day.
    mutating func setFirstDay(_ day: Date, calendar: Calendar = .current) {
        let previous = firstDay
        firstDay = day
        guard let lastDay else { return }
        let gap = calendar.dateComponents([.day], from: previous, to: lastDay).day ?? 0
        guard gap >= 0 else { return }
        self.lastDay = calendar.date(byAdding: .day, value: gap, to: day)
    }

    /// Off and Follow system always save; On needs the first day, a subject, a message,
    /// and a last day not before the first.
    var canSave: Bool {
        switch mode {
        case .off, .followSystem:
            return true
        case .on:
            if let lastDay, lastDay < firstDay { return false }
            return !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The online command a save runs (ADR-0068). Dates go up as UTC instants of local
    /// midnight — the first day's, and the one after the last day — as the web's
    /// `toISOString()` sends them.
    func command(accountId: Int64, calendar: Calendar = .current) -> SettingsCommand {
        if mode == .followSystem { return .followSystemOutOfOffice(accountId: accountId) }
        let start = calendar.startOfDay(for: firstDay)
        let end = lastDay.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return .saveOutOfOffice(
            accountId: accountId,
            OutOfOfficeRequest(
                enabled: mode == .on,
                start: Self.isoString(start),
                end: end.map(Self.isoString),
                subject: subject,
                message: message
            )
        )
    }

    // MARK: - JSON

    struct State: Decodable, Equatable {
        var enabled: Bool
        var start: String?
        var end: String?
        var subject: String?
        var message: String?
    }

    static func state(_ json: String?) -> State? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(State.self, from: Data(json.utf8))
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
