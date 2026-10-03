// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// "Always show images from this sender", as a queued operation: applied to every stored body
/// from the sender at once, and told to the server when the drainer can.
@Suite("Sender trust queue")
struct SenderTrustQueueTests {
    private static let trustRoute = RequestMatcher.method("PUT") && RequestMatcher.pathContains("/trustedsenders/")
    private static let untrustRoute =
        RequestMatcher.method("DELETE") && RequestMatcher.pathContains("/trustedsenders/")

    /// The fixture plus three messages with bodies: two from one sender spelled two ways, and
    /// one from somebody else.
    private struct Senders {
        var fixture: QueueTest.Fixture
        var annUpper: Int64
        var annLower: Int64
        var other: Int64

        func trusted(_ messageId: Int64) async throws -> Bool {
            try #require(try await fixture.store.body(messageId: messageId)).body.isSenderTrusted
        }
    }

    private static func make() async throws -> Senders {
        let fixture = try await QueueTest.make()
        let senders = ["Ann@Example.invalid", "ann@example.invalid", "bob@example.invalid"]
        let ids = try await fixture.store.upsert(
            envelopes: senders.enumerated().map { offset, email in
                let remoteId = Int64(500 + offset)
                return EnvelopeWrite(
                    remoteId: remoteId,
                    mailboxId: fixture.inboxId,
                    accountId: fixture.accountId,
                    sentAt: 1_700_000_000 + remoteId,
                    syncedAt: 1_700_000_000 + remoteId,
                    messageId: "<trust-\(remoteId)@example.invalid>",
                    threadRootId: "trust-\(remoteId)",
                    subject: "Trust \(remoteId)",
                    previewText: "",
                    flags: MessageFlags(),
                    fromEmail: email,
                    fromLabel: nil,
                    addresses: [EnvelopeAddress(kind: .from, email: email, label: nil)]
                )
            }
        )
        for id in ids {
            try await fixture.store.upsert(
                body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: true, html: "<p></p>"), for: id)
        }
        return Senders(fixture: fixture, annUpper: ids[0], annLower: ids[1], other: ids[2])
    }

    @Test func trustingQueuesOneRowAndTrustsEveryBodyFromTheSender() async throws {
        let senders = try await Self.make()
        let fixture = senders.fixture

        try await fixture.queue.perform(
            .trustSender(email: "ANN@example.invalid", trusted: true),
            accountId: fixture.accountId
        )

        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == OperationKind.trustSender.rawValue)
        #expect(try await senders.trusted(senders.annUpper))
        #expect(try await senders.trusted(senders.annLower))
        #expect(try await senders.trusted(senders.other) == false)
        // Offline is the default here: nothing was sent, and nothing needed to be.
        #expect(await fixture.transport.sendCount == 0)
    }

    @Test func aBodyFetchedWhileTrustIsQueuedKeepsTheTrust() async throws {
        let senders = try await Self.make()
        let fixture = senders.fixture
        try await fixture.queue.perform(
            .trustSender(email: "ann@example.invalid", trusted: true),
            accountId: fixture.accountId
        )

        // The server has not heard yet, so a refetched body says untrusted.
        try await fixture.store.upsert(
            body: MessageBodyWrite(fetchedAt: 2, hasHtmlBody: true, html: "<p></p>", isSenderTrusted: false),
            for: senders.annLower
        )

        #expect(try await senders.trusted(senders.annLower))
    }

    @Test func drainingTrustSendsPut() async throws {
        let senders = try await Self.make()
        let fixture = senders.fixture
        await fixture.transport.stub(Self.trustRoute, with: .status(200))

        try await fixture.queue.perform(
            .trustSender(email: "ann@example.invalid", trusted: true),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        let request = try #require(await fixture.transport.requests.first)
        #expect(await fixture.transport.sendCount == 1)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path.contains("/trustedsenders/") == true)
        #expect(try await fixture.rows().isEmpty)
        #expect(try await senders.trusted(senders.annUpper))
    }

    @Test func drainingDistrustSendsTheUntrustRoute() async throws {
        let senders = try await Self.make()
        let fixture = senders.fixture
        await fixture.transport.stub(Self.untrustRoute, with: .status(200))

        try await fixture.queue.perform(
            .trustSender(email: "ann@example.invalid", trusted: false),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        let request = try #require(await fixture.transport.requests.first)
        #expect(await fixture.transport.sendCount == 1)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path.contains("/trustedsenders/") == true)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test func trustThenDistrustForOneSenderSendsOnlyTheLatest() async throws {
        let senders = try await Self.make()
        let fixture = senders.fixture
        await fixture.transport.stub(Self.trustRoute, with: .status(200))
        await fixture.transport.stub(Self.untrustRoute, with: .status(200))

        try await fixture.queue.perform(
            .trustSender(email: "Ann@Example.invalid", trusted: true),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .trustSender(email: "ann@example.invalid", trusted: false),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        #expect(await fixture.transport.sendCount == 1)
        #expect(await fixture.transport.requests.first?.httpMethod == "DELETE")
        #expect(try await fixture.rows().isEmpty)
        #expect(try await senders.trusted(senders.annUpper) == false)
    }
}
