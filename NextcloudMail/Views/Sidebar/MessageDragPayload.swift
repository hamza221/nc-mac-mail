// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreTransferable
import UniformTypeIdentifiers

/// What a message drag carries from the message list (WS-29, the source) to a sidebar folder
/// (WS-28, the target): local ids only (ADR-0033), never a subject or address, so nothing a
/// drag leaves on the pasteboard identifies mail.
///
/// `accountId` rides along so a folder can refuse a drop from another account without a
/// database read: moves never cross accounts (§3.4).
nonisolated struct MessageDragPayload: Codable, Hashable, Sendable, Transferable {
    /// Local `message.id`s of the rows the user dragged.
    let messageIds: [Int64]
    /// Local `mailbox.id` the messages are in; dropping on it is a no-op.
    let sourceMailboxId: Int64
    /// Local `account.id` both the messages and any valid target belong to.
    let accountId: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ncMailMessageDrag)
    }
}

extension UTType {
    /// The in-app message drag. Exported rather than borrowing `.json`, so no other app's
    /// drop target accepts a payload that means nothing outside this one, and no folder row
    /// accepts a stray JSON file dragged in from Finder.
    nonisolated static let ncMailMessageDrag = UTType(
        exportedAs: "com.nextcloud.mail.message-drag", conformingTo: .data)
}
