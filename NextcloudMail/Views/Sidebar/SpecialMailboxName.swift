// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore

/// Special top-level folders carry the translated name whatever the server calls them.
///
/// One table for every place a folder is named — the sidebar row and the list's window
/// title — so a mailbox the sidebar calls "Inbox" is not "INBOX" in the toolbar above it.
/// `nonisolated`: a pure table, read from `MailboxRecord`, which is not main-actor bound.
nonisolated enum SpecialMailboxName {
    static func localized(role: String?) -> String? {
        switch role?.lowercased() {
        case "inbox": String(localized: "Inbox")
        case "drafts": String(localized: "Drafts")
        case "sent": String(localized: "Sent")
        case "trash": String(localized: "Trash")
        case "junk": String(localized: "Junk")
        case "archive": String(localized: "Archive")
        case "all": String(localized: "All")
        default: nil
        }
    }
}

nonisolated extension MailboxRecord {
    /// The name the sidebar shows for this mailbox: the translated special name for a
    /// top-level special folder, the server's display name otherwise. A subfolder keeps its
    /// own name even when the server flags it special, as the sidebar's depth-0 rule does.
    var localizedDisplayName: String {
        let isTopLevel = delimiter.map { $0.isEmpty || !name.contains($0) } ?? true
        guard isTopLevel, let special = SpecialMailboxName.localized(role: specialRole) else { return displayName }
        return special
    }
}
