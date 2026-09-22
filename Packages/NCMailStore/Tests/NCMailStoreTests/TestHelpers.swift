// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB

@testable import NCMailStore

/// Locates `docs/reference/schema.sql` without a bundled resource.
///
/// The package manifest belongs to WS-00 and declares no test resources, so the reference is
/// found by walking up from this file until the repository root shows itself. That also keeps
/// the test honest: it reads the same file a reviewer reads, not a copy that could go stale.
enum ReferenceSchema {
    static let relativePath = "docs/reference/schema.sql"

    static func load() throws -> String {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        if let root = ProcessInfo.processInfo.environment["NCMAIL_REPO_ROOT"] {
            return try String(
                contentsOf: URL(filePath: root).appending(path: relativePath),
                encoding: .utf8
            )
        }
        throw TestError.referenceSchemaNotFound
    }
}

/// Reads a file recorded from a live server by `Scripts/record-fixtures.sh`.
///
/// By path, for the reason in [ADR-0022](../../../../docs/decisions/0022-fixtures-by-path-not-bundle.md),
/// and because `NCMailStore` cannot depend on `NCMailTestSupport` — that package depends on
/// this one, and the other direction would be a cycle. Only the sizing measurement uses it;
/// the fixtures were recorded with `--scrub-content`, so their subjects and previews are the
/// literal strings "Subject redacted" and "Preview redacted" and are no use for anything that
/// reads text.
enum RecordedFixture {
    static func load(_ name: String) throws -> String {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        let relative = "Packages/NCMailTestSupport/Sources/NCMailTestSupport/Resources/Fixtures"
        while directory.path != "/" {
            let candidate = directory.appending(path: relative).appending(path: name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw TestError.fixtureNotFound(name)
    }
}

enum TestError: Error {
    case referenceSchemaNotFound
    case fixtureNotFound(String)
}

/// A comparable form of a schema: whitespace and comments flattened, names and types untouched.
///
/// Keyed by object name so a failure names the table that diverged instead of printing two
/// thousand characters and leaving the reader to diff them by eye.
enum SchemaDump {
    /// Everything SQLite generates for itself, and has no opinion about: the FTS5 shadow
    /// tables, GRDB's migration bookkeeping, and the sequence table AUTOINCREMENT creates.
    static func isGenerated(_ name: String) -> Bool {
        name.hasPrefix("sqlite_") || name.hasPrefix("grdb_") || name.hasPrefix("messageSearch_")
    }

    /// The projection happens inside the read closure on purpose. GRDB marks `Row: Sendable`
    /// unavailable because a row can still reference database memory, so the strings have to be
    /// taken out of it before the closure returns.
    static func ofDatabase(_ store: MailStore) async throws -> [String: String] {
        try await store.read { db in
            var dump: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL")
            for row in rows {
                let name: String = row["name"]
                guard !isGenerated(name) else { continue }
                dump[name] = normalise(row["sql"])
            }
            return dump
        }
    }

    static func ofSQL(_ sql: String) -> [String: String] {
        var dump: [String: String] = [:]
        for statement in statements(in: sql) {
            let normalised = normalise(statement)
            guard normalised.uppercased().hasPrefix("CREATE") else { continue }
            guard let name = objectName(of: normalised) else { continue }
            dump[name] = normalised
        }
        return dump
    }

    /// Splits on semicolons, except the ones inside a trigger body, which are part of it.
    private static func statements(in sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var insideTrigger = false
        for line in sql.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: false)[0]
            current += stripped + "\n"
            let upper = stripped.uppercased()
            if upper.contains("CREATE TRIGGER") { insideTrigger = true }
            if insideTrigger {
                if upper.contains("END;") {
                    insideTrigger = false
                    statements.append(current)
                    current = ""
                }
                continue
            }
            if stripped.contains(";") {
                statements.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { statements.append(current) }
        return statements
    }

    private static func objectName(of statement: String) -> String? {
        // "CREATE [UNIQUE] INDEX name", "CREATE [VIRTUAL] TABLE name", "CREATE TRIGGER name".
        let words = statement.split(separator: " ").map(String.init)
        guard let keyword = words.firstIndex(where: { ["TABLE", "INDEX", "TRIGGER"].contains($0.uppercased()) })
        else { return nil }
        guard keyword + 1 < words.count else { return nil }
        return words[keyword + 1]
            .prefix(while: { $0 != "(" })
            .trimmingCharacters(in: .whitespaces)
    }

    /// Comments out, whitespace flattened, spacing around brackets and commas made uniform.
    /// Names, types, constraints and case are left exactly as written.
    static func normalise(_ sql: String) -> String {
        let withoutComments =
            sql
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: " ")
        let collapsed = withoutComments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return
            collapsed
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
    }
}

/// Rows to test against, generated here rather than taken from a fixture.
///
/// The recorded fixtures were captured with `--scrub-content`, so every subject in them is the
/// literal string "Subject redacted". A search index tested against a corpus with one distinct
/// subject proves nothing, so the text in these tests is written for the test.
enum Seed {
    static func account(id: Int64 = 1) -> AccountWrite {
        AccountWrite(id: id, name: "Test", emailAddress: "test@example.invalid", rawJSON: "{}")
    }

    static func mailbox(id: Int64, name: String = "INBOX", subscribed: Bool = true) -> MailboxWrite {
        MailboxWrite(
            id: id,
            accountId: 1,
            name: name,
            delimiter: ".",
            displayName: name,
            isSubscribed: subscribed
        )
    }

    static func envelope(
        id: Int64,
        mailboxId: Int64 = 10,
        accountId: Int64 = 1,
        sentAt: Int64,
        subject: String = "A subject",
        preview: String = "Some preview",
        threadRootId: String? = nil,
        isSeen: Bool = false,
        addresses: [EnvelopeAddress] = [EnvelopeAddress(kind: .from, email: "a@example.invalid", label: "Ada")]
    ) -> EnvelopeWrite {
        var flags = MessageFlags()
        flags.isSeen = isSeen
        return EnvelopeWrite(
            id: id,
            mailboxId: mailboxId,
            accountId: accountId,
            sentAt: sentAt,
            syncedAt: sentAt,
            threadRootId: threadRootId,
            subject: subject,
            previewText: preview,
            flags: flags,
            fromEmail: addresses.first?.email,
            fromLabel: addresses.first?.label,
            addresses: addresses
        )
    }

    /// An account with one mailbox, ready for envelopes.
    static func base(_ store: MailStore, mailboxId: Int64 = 10) async throws {
        try await store.upsert(accounts: [account()])
        try await store.upsert(mailboxes: [mailbox(id: mailboxId)], accountId: 1)
    }
}

/// Writes a measurement where the test log will show it.
///
/// `print` is banned in this repository because mail bodies must never reach stdout. A
/// benchmark number is neither a body nor an address, and it has to be readable in CI output,
/// so it goes to stderr explicitly rather than through a logger nobody reads.
func reportMeasurement(_ text: String) {
    FileHandle.standardError.write(Data(("  [measured] " + text + "\n").utf8))
}

/// Milliseconds spent in `work`, as a Double.
func milliseconds(_ work: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
