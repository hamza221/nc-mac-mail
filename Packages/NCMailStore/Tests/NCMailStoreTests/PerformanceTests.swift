// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// Measurements, not thresholds.
///
/// Each test reports its number to stderr and asserts a ceiling roughly ten times the target
/// in the brief. A tight assertion on a shared CI machine fails for reasons that have nothing
/// to do with the code; a loose one still catches the thing worth catching, which is an index
/// quietly falling out of use and turning a seek into a scan.
@Suite("Performance", .serialized)
struct PerformanceTests {
    static let messageCount: Int64 = 50_000
    static let threadSize: Int64 = 5

    /// 50,000 envelopes through the real write path, so the index rows and addresses are there
    /// too and the query is measured against a realistic table rather than a bare one.
    static func seed(_ store: MailStore) async throws -> Double {
        try await Seed.base(store)
        let start = DispatchTime.now().uptimeNanoseconds
        var batch: [EnvelopeWrite] = []
        batch.reserveCapacity(1000)
        for id in Int64(1)...messageCount {
            batch.append(
                Seed.envelope(
                    id: id,
                    sentAt: 1_600_000_000 + id,
                    subject: "Message \(id) about \(topics[Int(id) % topics.count])",
                    preview: "The quick brown fox \(id) jumped over the lazy dog",
                    threadRootId: "thread-\(id / threadSize)",
                    isSeen: id % 3 == 0,
                    addresses: [
                        EnvelopeAddress(
                            kind: .from, email: "sender\(id % 500)@example.invalid", label: "Sender \(id % 500)"),
                        EnvelopeAddress(kind: .to, email: "me@example.invalid", label: "Me"),
                    ]
                )
            )
            if batch.count == 1000 {
                try await store.upsert(envelopes: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await store.upsert(envelopes: batch) }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static let topics = [
        "invoices", "hedgehogs", "the roadmap", "deployment", "lunch", "the outage",
        "onboarding", "quarterly numbers",
    ]

    @Test func theWindowedListIsFastAtFiftyThousandRows() async throws {
        let store = try MailStore.inMemory()
        let seedMilliseconds = try await Self.seed(store)
        reportMeasurement("seeded \(Self.messageCount) envelopes in \(rounded(seedMilliseconds)) ms")

        let total = try await store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? 0 }
        #expect(total == Int(Self.messageCount))

        // Warm the statement cache once; the number people care about is the steady state,
        // which is what happens on every scroll.
        _ = try await store.messages(mailboxId: 10, view: .flat, range: 0..<50)
        _ = try await store.messages(mailboxId: 10, view: .threaded, range: 0..<50)

        let flat = try await Self.best(of: 5) {
            _ = try await store.messages(mailboxId: 10, view: .flat, range: 0..<50)
        }
        let threaded = try await Self.best(of: 5) {
            _ = try await store.messages(mailboxId: 10, view: .threaded, range: 0..<50)
        }
        let deepWindow = try await Self.best(of: 5) {
            _ = try await store.messages(mailboxId: 10, view: .flat, range: 25_000..<25_050)
        }

        reportMeasurement("flat list, first 50 of \(Self.messageCount): \(rounded(flat)) ms")
        reportMeasurement("threaded list, first 50 of \(Self.messageCount): \(rounded(threaded)) ms")
        reportMeasurement("flat list, rows 25000-25050: \(rounded(deepWindow)) ms")

        #expect(flat < 100, "flat list took \(rounded(flat)) ms")
        #expect(threaded < 100, "threaded list took \(rounded(threaded)) ms")
    }

    @Test func theBackfillPickerIsFastWithSeveralAccounts() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.seed(store)
        // A second account with nothing downloaded, which is the case the index ordering was
        // changed for: without `accountId` leading, its rows are walked before account 1's.
        try await store.upsert(accounts: [AccountWrite(id: 2, name: "Other", emailAddress: "b@example.invalid")])
        try await store.upsert(
            mailboxes: [MailboxWrite(id: 20, accountId: 2, name: "INBOX", displayName: "INBOX", isSubscribed: true)],
            accountId: 2)
        try await store.upsert(
            envelopes: (1...2000).map {
                Seed.envelope(id: 900_000 + $0, mailboxId: 20, accountId: 2, sentAt: 1_900_000_000 + $0)
            }
        )
        try await store.setBodyState(.present, messageIds: Array(Int64(1)...Int64(49_000)))

        _ = try await store.nextBodyBackfillBatch(accountId: 1, limit: 20)
        let picker = try await Self.best(of: 5) {
            _ = try await store.nextBodyBackfillBatch(accountId: 1, limit: 20)
        }
        reportMeasurement("backfill picker, 20 of 1000 outstanding across 2 accounts: \(rounded(picker)) ms")
        #expect(picker < 100)
    }

    /// The disk figures that replace the estimates in `local-mirror.md`.
    ///
    /// Ten thousand messages, not fifty: the per-message cost is what the table is made of, and
    /// measuring the smallest row and multiplying is honest where writing 1.5 GB of body text
    /// into a temporary file is merely slow.
    ///
    /// The body is the recorded `message-html-plain.html` from a live server, with a unique
    /// paragraph per message so the FTS dictionary is not one document repeated. A hand-written
    /// body would measure the size of my idea of an email.
    ///
    /// Off by default, because it writes a real file and the suite's rule is that every test
    /// uses an in-memory database. Run it with
    /// `NCMAIL_SIZING=1 swift test --filter sizingOfAMirrorOnDisk`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NCMAIL_SIZING"] == "1"))
    func sizingOfAMirrorOnDisk() async throws {
        let count: Int64 = 10_000
        let recordedBody = try RecordedFixture.load("message-html-plain.html")
        reportMeasurement("recorded body: \(recordedBody.utf8.count) bytes of sanitised HTML")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ncmail-sizing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try MailStore(url: directory.appending(path: "mirror.sqlite"))
        try await Seed.base(store)
        try await store.upsert(
            envelopes: (1...count).map {
                Seed.envelope(
                    id: $0,
                    sentAt: 1_600_000_000 + $0,
                    subject: "Message \($0) about \(Self.topics[Int($0) % Self.topics.count])",
                    threadRootId: "thread-\($0 / Self.threadSize)",
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "sender\($0 % 500)@example.invalid", label: "Sender"),
                        EnvelopeAddress(kind: .to, email: "me@example.invalid", label: "Me"),
                    ]
                )
            }
        )
        try await store.vacuum()
        let envelopesOnly = try await settledSize(of: store)
        reportMeasurement(
            "\(count) envelopes + addresses + index: \(megabytes(envelopesOnly)) MB "
                + "(\(perMessage(envelopesOnly, count)) bytes each)"
        )

        for id in Int64(1)...count {
            try await store.upsert(
                body: MessageBodyWrite(
                    fetchedAt: 1,
                    hasHtmlBody: true,
                    html: "<p>Message \(id), \(Self.topics[Int(id) % Self.topics.count])</p>" + recordedBody,
                    plainBody: nil
                ),
                for: id
            )
        }
        try await store.vacuum()
        let withBodies = try await settledSize(of: store)
        let footprint = try await store.storageFootprint(accountId: 1)

        reportMeasurement(
            "\(count) messages with bodies: \(megabytes(withBodies)) MB total "
                + "(\(perMessage(withBodies, count)) bytes each)"
        )
        reportMeasurement("of which stored body text: \(megabytes(footprint.bodyBytes)) MB")

        // Emptying the index's body column and rebuilding the file separates the two costs the
        // sizing table lists apart: what the bodies take, and what indexing them takes.
        try await store.write { db in try db.execute(sql: "UPDATE messageSearch SET body = ''") }
        try await store.vacuum()
        let withoutBodyIndex = try await settledSize(of: store)
        reportMeasurement("body search index: \(megabytes(withBodies - withoutBodyIndex)) MB")
        reportMeasurement("bodies without their index: \(megabytes(withoutBodyIndex - envelopesOnly)) MB")
        #expect(withBodies > withoutBodyIndex)
    }

    /// The fastest of `count` runs. The fastest, not the mean: a slow run measures whatever else
    /// the machine was doing, and the question here is what the query costs.
    static func best(of count: Int, _ work: () async throws -> Void) async rethrows -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<count {
            let start = DispatchTime.now().uptimeNanoseconds
            try await work()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return best
    }
}

private func rounded(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f", Double(bytes) / 1_048_576)
}

/// Pages times page size, which is the database proper.
///
/// `MailStore.fileSizeOnDisk()` deliberately counts the write-ahead log too, because that is
/// space the user's disk has given up. For a sizing table the settled figure is the one that
/// generalises: a WAL left behind by a `VACUUM` of a 700 MB file says nothing about how big a
/// mailbox is.
private func settledSize(of store: MailStore) async throws -> Int64 {
    try await store.read { db in
        let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
        return pages * pageSize
    }
}

private func perMessage(_ bytes: Int64, _ count: Int64) -> String {
    String(format: "%.0f", Double(bytes) / Double(count))
}
