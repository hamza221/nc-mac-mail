// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore

/// The one place a `MailboxRecord` becomes what `MailboxTree` needs.
///
/// Plain field access, plus one small decode: the server's ACL rights (`myAcls`) and `shared`
/// flag have no column of their own yet, so they are read from the row's `rawJSON` -- the
/// server's own payload, which the mirror keeps verbatim. No GRDB symbol crosses out of this
/// file. See [ADR-0046](../../../docs/decisions/0046-mailboxtree-takes-its-own-row-type.md)
/// for why `MailboxTree` cannot take a `MailboxRecord` directly.
extension MailboxRecord {
    var treeRow: MailboxTreeRow {
        let extras = ServerExtras(rawJSON: rawJSON)
        return MailboxTreeRow(
            id: id,
            name: name,
            delimiter: delimiter,
            specialRole: specialRole,
            isSelectable: isSelectable,
            isSubscribed: isSubscribed,
            unreadCount: unreadCount,
            hasSyncFailure: syncFailureCount > 0,
            remoteId: remoteId,
            totalCount: totalCount,
            syncInBackground: syncInBackground,
            rights: extras.myAcls,
            isShared: extras.shared ?? false
        )
    }
}

/// The two mailbox fields the sidebar needs that the mirror does not split into columns.
/// A row whose JSON lacks them (or a placeholder row a queued create wrote, `{}`) decodes to
/// nils: no ACL restriction and not shared, which is the web client's reading too.
nonisolated private struct ServerExtras: Decodable {
    var myAcls: String?
    var shared: Bool?

    init(rawJSON: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(rawJSON.utf8))) ?? Self()
    }

    private init() {}

    private enum CodingKeys: String, CodingKey { case myAcls, shared }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        myAcls = try? container.decodeIfPresent(String.self, forKey: .myAcls)
        shared = try? container.decodeIfPresent(Bool.self, forKey: .shared)
    }
}
