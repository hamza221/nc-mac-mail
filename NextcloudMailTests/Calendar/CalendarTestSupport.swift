// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

enum CalendarTestSupport {
    struct TimedOut: Error {}

    /// The recorded iMIP message (envelope, then the body with its `scheduling` and its
    /// `invite.ics` attachment) in `mailboxId`. Answers the local message id.
    static func seedImipMessage(store: MailStore, accountId: Int64, mailboxId: Int64) async throws -> Int64 {
        let ids = try await store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: 263, mailboxId: mailboxId, accountId: accountId, sentAt: 1_791_118_166,
                syncedAt: 1_791_118_200, subject: "Invitation: WS34 seeded invitation",
                fromEmail: "alice@example.net", fromLabel: "Alice")
        ])
        let messageId = try #require(ids.first)
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1_791_118_200,
                plainBody: "You are invited to WS34 seeded invitation.",
                schedulingJSON: try CalendarInvitationTests.recordedSchedulingJSON(),
                attachments: [
                    AttachmentWrite(
                        attachmentId: "2", fileName: "invite.ics", mime: "application/ics", size: 505,
                        disposition: "attachment", isCalendarEvent: true)
                ]),
            for: messageId)
        return messageId
    }

    /// Polls `condition` on the main actor for up to two seconds.
    @MainActor
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut()
    }
}
