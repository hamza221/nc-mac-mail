// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// Pure text and encoding helpers for the Settings scene. Nothing here touches the database
/// or the network; every function is a straight mapping from a value already in hand to a
/// string another value another view can bind to.
enum SettingsFormatting {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    private static let messageCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func messageCount(_ value: Int) -> String {
        messageCountFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let lastSyncFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "3 minutes ago", or "never" for an account whose mirror has not synced yet.
    static func lastSync(_ unixSeconds: Int64?) -> String {
        guard let unixSeconds else { return String(localized: "Never") }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        return lastSyncFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// One line for the storage panel's second row: what stage the mirror is in, and how
    /// much of it is left, computed from ``MirrorState`` and ``MirrorProgress`` alone.
    /// Nothing here is tallied or remembered, so it reads correctly right after a crash the
    /// same way `local-mirror.md` promises the underlying counts do.
    static func mirrorStatus(state: MirrorState, progress: MirrorProgress?, isPaused: Bool) -> String {
        if isPaused {
            if let progress, !progress.isComplete {
                return String(
                    format: String(localized: "Paused · %@ of %@ downloaded"),
                    messageCount(progress.bodiesPresent),
                    messageCount(progress.totalMessages)
                )
            }
            return String(localized: "Paused")
        }
        switch state {
        case .idle:
            return String(localized: "Not started")
        case .priming, .envelopes:
            guard let progress, progress.mailboxesRemaining > 0 else {
                return String(localized: "Finding messages")
            }
            return String(
                format: String(localized: "Finding messages · %@ mailboxes left"),
                messageCount(progress.mailboxesRemaining)
            )
        case .bodies:
            guard let progress else { return String(localized: "Downloading messages") }
            let remaining = max(0, progress.totalMessages - progress.bodiesPresent - progress.bodiesFailed)
            guard remaining > 0 else { return String(localized: "Finishing up") }
            var text = String(
                format: String(localized: "Downloading bodies · %@ remaining"),
                messageCount(remaining)
            )
            if progress.bodiesFailed > 0 {
                text +=
                    " "
                    + String(
                        format: String(localized: "(%@ could not be fetched)"),
                        messageCount(progress.bodiesFailed)
                    )
            }
            return text
        case .complete:
            return String(localized: "Mirror complete")
        case .failed:
            return String(localized: "Mirror stopped after an error")
        case .paused:
            return String(localized: "Paused")
        }
    }
}

/// When to mark a message read after it is opened, persisted once for the whole app rather
/// than per mailbox. ``ListView`` in `NavigationState` is the precedent this follows.
///
/// Settings ▸ Messages writes it alongside the server's `auto-mark-as-read`
/// (``AutoMarkAsRead/localDelay``); `MessageActions.messageOpened(_:)` reads it.
enum MarkAsReadDelay: Hashable, Sendable {
    case immediately
    case after(seconds: Int)
    case manually

    /// The `meta` key, here so the writer and the reader cannot drift apart.
    static let metaKey = "settings.markAsReadDelay"

    var metaValue: String {
        switch self {
        case .immediately: "immediately"
        case .manually: "manually"
        case .after(let seconds): "after:\(seconds)"
        }
    }

    init(metaValue: String?) {
        guard let metaValue else {
            self = .immediately
            return
        }
        if metaValue == "manually" {
            self = .manually
        } else if metaValue.hasPrefix("after:"), let seconds = Int(metaValue.dropFirst("after:".count)) {
            self = .after(seconds: seconds)
        } else {
            self = .immediately
        }
    }
}
