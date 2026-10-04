// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import OSLog

/// The outbox engine's logger.
///
/// Same discipline as `SyncLog`: account ids, draft ids, server ids, states and
/// `MailError.description` only, all `.public`. A subject, an address, a file name or a body
/// is never interpolated here — `syncError` on the row is where a user-facing reason goes.
enum OutboxLog {
    static let outbox = Logger(subsystem: "com.nextcloud.mail.macos", category: "outbox")
}
