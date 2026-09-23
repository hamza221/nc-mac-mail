// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// The stored avatar for one email address, or nil if nothing has been recorded for it.
    ///
    /// The picture of a person, keyed by address and shared across accounts and servers,
    /// because the same person has the same address on both (ADR-0033).
    ///
    /// Three answers, and the caller needs all three. Nil means nobody has asked the server
    /// yet. A row with ``AvatarRecord/missing`` set means the server answered 404 and there
    /// is no point asking again this launch — the library draws coloured initials and needs
    /// no bytes. Anything else carries ``AvatarRecord/data``.
    ///
    /// The address is matched case-insensitively: a header may spell it any way and it is
    /// still the same mailbox.
    public func avatar(for email: String) async throws -> AvatarRecord? {
        try await dbQueue.read { db in
            try AvatarRecord.fetchOne(
                db,
                sql: "SELECT * FROM avatar WHERE email = ? COLLATE NOCASE",
                arguments: [email]
            )
        }
    }
}
