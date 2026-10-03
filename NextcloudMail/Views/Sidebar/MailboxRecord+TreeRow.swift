// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore

/// The one place a `MailboxRecord` becomes what `MailboxTree` needs.
///
/// Plain field access, nothing else -- no JSON, no GRDB symbol crosses out of this file. See
/// [ADR-0046](../../../docs/decisions/0046-mailboxtree-takes-its-own-row-type.md) for why
/// `MailboxTree` cannot take a `MailboxRecord` directly.
extension MailboxRecord {
    var treeRow: MailboxTreeRow {
        MailboxTreeRow(
            id: id,
            name: name,
            delimiter: delimiter,
            specialRole: specialRole,
            isSelectable: isSelectable,
            isSubscribed: isSubscribed,
            unreadCount: unreadCount,
            hasSyncFailure: syncFailureCount > 0
        )
    }
}
