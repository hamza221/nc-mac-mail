// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailStore

/// `messages(messageIdHeader:)`, the lookup behind `ncmail://open/<Message-ID>` (WS-42).
@Suite("Message-ID lookup")
struct MessageIdLookupTests {
    private static func envelope(
        remoteId: Int64, sentAt: Int64, header: String?, mailboxId: Int64 = 10
    )
        -> EnvelopeWrite
    {
        var envelope = Seed.envelope(remoteId: remoteId, mailboxId: mailboxId, sentAt: sentAt)
        envelope.messageId = header
        return envelope
    }

    @Test func findsEveryCopyNewestFirstAndMatchesExactly() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Archive")], accountId: 1)
        try await store.upsert(envelopes: [
            Self.envelope(remoteId: 1, sentAt: 100, header: "<a@example.invalid>"),
            Self.envelope(remoteId: 2, sentAt: 200, header: "<a@example.invalid>", mailboxId: 11),
            Self.envelope(remoteId: 3, sentAt: 300, header: "<b@example.invalid>"),
            Self.envelope(remoteId: 4, sentAt: 400, header: nil),
        ])

        let copies = try await store.messages(messageIdHeader: "<a@example.invalid>")
        #expect(copies.map(\.remoteId) == [2, 1])
        // Exact: no brackets is a different header, and case is not folded.
        #expect(try await store.messages(messageIdHeader: "a@example.invalid").isEmpty)
        #expect(try await store.messages(messageIdHeader: "<A@example.invalid>").isEmpty)
        #expect(try await store.messages(messageIdHeader: "").isEmpty)
    }

    /// No index on `message.messageId`: a link open is a one-off read, so the scan is
    /// measured rather than indexed. Ceiling ~10× the measured number.
    @Test func aScanOfTenThousandRowsIsCheap() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let envelopes = (1...10_000).map {
            Self.envelope(remoteId: Int64($0), sentAt: Int64($0), header: "<m\($0)@example.invalid>")
        }
        try await store.upsert(envelopes: envelopes)

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = try await store.messages(messageIdHeader: "<m5000@example.invalid>")
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            #expect(found.count == 1)
        }
        reportMeasurement("Message-ID lookup over 10 000 rows: \(String(format: "%.2f", best)) ms")
        #expect(best < 50)
    }
}
