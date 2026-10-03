// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import OSLog

/// One logger for the mirror.
///
/// The vocabulary is deliberately tiny: account ids, mailbox ids, message ids, counts and
/// `MailError.description`, all of which are safe to mark `.public`. A mailbox name is a
/// folder the user named and a subject is mail; neither is interpolated here, at any level,
/// so there is no `.private` interpolation in this package to get wrong.
enum MirrorLog {
    static let mirror = Logger(subsystem: "com.nextcloud.mail.macos", category: "mirror")
}
