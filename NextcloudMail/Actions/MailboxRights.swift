// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// A mailbox's IMAP ACL rights (RFC 4314), as the server's `myAcls` string carries them.
///
/// The mirror has no column for it; the mailbox payload's `rawJSON` keeps it (ADR-0020), so
/// this reads it from there. Absent or unparseable means "every right" — the web's
/// `myAcls === undefined || includes(…)` rule, and the case for servers without the ACL
/// extension.
struct MailboxRights: Equatable, Sendable {
    /// Nil when the server did not say.
    let acls: String?

    static let unrestricted = MailboxRights(acls: nil)

    init(acls: String?) {
        self.acls = acls
    }

    init(mailbox: MailboxRecord) {
        let object = (try? JSONSerialization.jsonObject(with: Data(mailbox.rawJSON.utf8))) as? [String: Any]
        self.init(acls: object?["myAcls"] as? String)
    }

    private func has(_ rights: String) -> Bool {
        guard let acls else { return true }
        return rights.allSatisfy(acls.contains)
    }

    /// `w`: flags other than seen and deleted — star, important, junk, tags.
    var canWrite: Bool { has("w") }
    /// `s`: the seen flag.
    var canSetSeen: Bool { has("s") }
    /// `t` and `e`: moving a message out, or deleting it.
    var canDelete: Bool { has("te") }
    /// `i`: a message can be moved in.
    var canInsert: Bool { has("i") }
}
