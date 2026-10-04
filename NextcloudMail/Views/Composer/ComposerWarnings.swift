// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What the composer warns about (§6.3, §6.4). Pure, so each trigger is a unit test.
nonisolated enum ComposerWarning: Hashable, Sendable {
    /// Blocking until "Send anyway": "Your message has no subject…".
    case noSubject
    /// Blocking until "Send anyway": "You mentioned an attachment. Did you forget to add it?"
    case forgottenAttachment
    /// Inline under To: "Messages with no 'To' recipients may be rejected…".
    case emptyTo
    /// Inline: replying to a noreply address.
    case noReply

    var message: String {
        switch self {
        case .noSubject:
            String(localized: "Your message has no subject. Do you want to send it anyway?")
        case .forgottenAttachment:
            String(localized: "You mentioned an attachment. Did you forget to add it?")
        case .emptyTo:
            String(localized: "Messages with no 'To' recipients may be rejected by some mail providers.")
        case .noReply:
            String(localized: "This message came from a noreply address so your reply will probably not be read.")
        }
    }

    /// The two that stop a send for confirmation; the others are inline hints.
    var isPreSend: Bool { self == .noSubject || self == .forgottenAttachment }

    struct Input: Sendable {
        var subject: String
        var to: [ComposerAddress]
        var cc: [ComposerAddress]
        var bcc: [ComposerAddress]
        /// The editor's text, plain — the keyword scan reads words, not markup.
        var bodyText: String
        var attachmentCount: Int
        /// The address being replied to, when this is a reply.
        var replyingTo: [ComposerAddress]
    }

    static func evaluate(_ input: Input) -> Set<ComposerWarning> {
        var warnings: Set<ComposerWarning> = []
        if input.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.insert(.noSubject)
        }
        if input.attachmentCount == 0, mentionsAttachment(input.bodyText) {
            warnings.insert(.forgottenAttachment)
        }
        if input.to.isEmpty, !(input.cc.isEmpty && input.bcc.isEmpty) {
            warnings.insert(.emptyTo)
        }
        if input.replyingTo.contains(where: isNoReply) {
            warnings.insert(.noReply)
        }
        return warnings
    }

    /// Words that mean "attachment", English plus the translations the web client ships for
    /// its two keywords. Matched as whole words, case-insensitively.
    static let attachmentKeywords: [String] = [
        "attachment", "attachments", "attached", "attach",
        "anhang", "angehängt", "anbei", "pièce jointe", "ci-joint", "joint", "adjunto", "adjunta",
        "allegato", "in allegato", "bijlage", "bijgevoegd", "anexo", "załącznik", "vedlegg", "bilaga",
        "附件", "添付",
    ]

    /// The web rule: a keyword written by the user, i.e. before the first quoted line
    /// (`>`) or signature delimiter (`--`).
    static func mentionsAttachment(_ text: String) -> Bool {
        var own: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("--") { break }
            own.append(line)
        }
        let lowered = own.joined(separator: "\n").lowercased()
        return attachmentKeywords.contains { keyword in
            lowered.range(
                of: #"(^|[^\p{L}])"# + NSRegularExpression.escapedPattern(for: keyword) + #"($|[^\p{L}])"#,
                options: .regularExpression
            ) != nil
        }
    }

    static func isNoReply(_ address: ComposerAddress) -> Bool {
        let local = address.email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return local == "noreply" || local == "no-reply" || local == "donotreply" || local == "do-not-reply"
    }
}

/// "Send later" presets (§6.8): tomorrow 09:00, tomorrow 14:00, Monday 09:00, and the custom
/// picker's default of now + 1 h on a five-minute step.
nonisolated enum SendLaterPreset: CaseIterable, Hashable, Sendable {
    case tomorrowMorning
    case tomorrowAfternoon
    case mondayMorning

    var title: String {
        switch self {
        case .tomorrowMorning: String(localized: "Tomorrow morning")
        case .tomorrowAfternoon: String(localized: "Tomorrow afternoon")
        case .mondayMorning: String(localized: "Monday morning")
        }
    }

    func date(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .tomorrowMorning:
            return Self.at(hour: 9, dayOffset: 1, from: now, calendar: calendar)
        case .tomorrowAfternoon:
            return Self.at(hour: 14, dayOffset: 1, from: now, calendar: calendar)
        case .mondayMorning:
            // The next Monday strictly after today: on a Monday it is a week away, like the
            // web client's `nextMonday`.
            let start = calendar.startOfDay(for: now)
            let monday =
                calendar.nextDate(
                    after: start, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? start
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: monday) ?? monday
        }
    }

    /// Custom's starting value: an hour from now, rounded up to the next five minutes.
    static func customDefault(from now: Date, calendar: Calendar = .current) -> Date {
        let later = now.addingTimeInterval(3600)
        let minute = calendar.component(.minute, from: later)
        let second = calendar.component(.second, from: later)
        let extra = (5 - minute % 5) % 5
        let rounded = later.addingTimeInterval(TimeInterval(extra * 60 - second))
        return extra == 0 && second == 0 ? later : rounded
    }

    private static func at(hour: Int, dayOffset: Int, from now: Date, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}
