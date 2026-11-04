// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// The list's window title names a mailbox the way the sidebar does.
@Suite("SpecialMailboxName")
struct SpecialMailboxNameTests {
    private func mailbox(name: String, displayName: String, role: String?) -> MailboxRecord {
        MailboxRecord(
            id: 10, accountId: 1, remoteId: 1010, name: name, delimiter: ".", displayName: displayName,
            specialRole: role)
    }

    @Test("a top-level special folder takes the translated name, not the server's INBOX")
    func topLevelSpecialIsTranslated() {
        #expect(mailbox(name: "INBOX", displayName: "INBOX", role: "inbox").localizedDisplayName == "Inbox")
    }

    @Test("a special-flagged subfolder keeps its own name, as the sidebar's depth rule does")
    func subfolderKeepsItsName() {
        let sent = mailbox(name: "INBOX.Sent Items", displayName: "Sent Items", role: "sent")
        #expect(sent.localizedDisplayName == "Sent Items")
    }

    @Test("an ordinary folder keeps the server's display name")
    func ordinaryFolder() {
        #expect(mailbox(name: "Projects", displayName: "Projects", role: nil).localizedDisplayName == "Projects")
    }
}
