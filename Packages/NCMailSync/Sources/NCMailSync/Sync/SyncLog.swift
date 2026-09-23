// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import OSLog

/// One logger for the sync engine, alongside the mirror's.
///
/// Same discipline as `MirrorLog`: the vocabulary is account ids, mailbox ids, message ids,
/// counts and `MailError.description`, every one of which is safe to mark `.public`. A
/// subject, an address and a folder name are never interpolated here at any level, so there
/// is no `.private` interpolation in this file to get wrong later.
enum SyncLog {
    static let sync = Logger(subsystem: "com.nextcloud.mail.macos", category: "sync")
}
