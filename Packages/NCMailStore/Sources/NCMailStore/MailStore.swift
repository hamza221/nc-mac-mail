// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import GRDB
import OSLog

/// The local mirror, and the only way into it.
///
/// Every read in the application goes through this type and every write from sync lands in
/// it. There is deliberately no network here: `NCMailStore` cannot see `NCMailNet`, which is
/// what turns "the network only writes to the database" from a convention into something the
/// compiler checks.
///
/// One `DatabaseQueue` rather than a pool. There is exactly one writer (the sync engine), and
/// WAL already lets readers proceed while it works, so a pool would buy contention handling
/// for contention that does not exist.
public final class MailStore: Sendable {
    /// Shared with `Search/**` (WS-11), which builds its own observations over the same queue.
    let dbQueue: DatabaseQueue

    /// Opens the mirror at `url`, creating it and applying every migration.
    ///
    /// - Throws: ``MailStoreError/unreadable(resultCode:message:)`` when SQLite says the file
    ///   is not a database it can read. That case is recoverable by deleting and re-mirroring,
    ///   which is why it is distinguishable from every other failure.
    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.label = "mirror"

        do {
            dbQueue = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
            try MailStoreMigrations.migrator.migrate(dbQueue)
        } catch let error as DatabaseError where error.isUnreadableDatabase {
            storeLog.error("mirror unreadable at open, result code \(error.resultCode.rawValue, privacy: .public)")
            throw MailStoreError.unreadable(resultCode: error.resultCode.rawValue, message: error.message ?? "")
        }
        storeLog.info("mirror opened, schema v\(MailStoreMigrations.currentVersion, privacy: .public)")
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try MailStoreMigrations.migrator.migrate(dbQueue)
    }

    /// A migrated, empty mirror that never touches the disk. Every test in the package uses one.
    public static func inMemory() throws -> MailStore {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "mirror-memory"
        // No WAL: an in-memory database has no journal to write, and asking for one reports
        // `memory` back rather than failing, which would make the request a lie in the log.
        return try MailStore(queue: DatabaseQueue(configuration: configuration))
    }

    /// The canonical on-disk location, inside the sandbox container.
    ///
    /// `Application Support` resolves to the container when the app is sandboxed and to the
    /// user's home when a test or tool is not, so no path is hard-coded here.
    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appending(path: "NextcloudMail", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory)
    }

    /// Raw SQL, for the queries inside this module that are not worth a DAO of their own.
    ///
    /// Not `public`: `Database` is GRDB's, and handing it out is how the app target ended up
    /// depending on GRDB without naming it (ADR-0029). Anything outside this module that needs
    /// the database needs a method on `MailStore` instead.
    func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbQueue.read(block)
    }

    func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbQueue.write(block)
    }

    /// One observation of `fetch`, started afresh for each iteration and delivered on the
    /// main actor.
    ///
    /// Every `observe…` method in this module is one line over this. Keeping the GRDB call
    /// in one place is what lets ``StoreObservation`` stay free of GRDB types.
    func observation<Element: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Element
    ) -> StoreObservation<Element> {
        let reader = dbQueue
        return StoreObservation { continuation in
            let cancellable = startTracking(
                fetch,
                in: reader,
                scheduling: .mainActor,
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            // Held by the continuation, which is held by the stream, which is held by the
            // iterator. Dropping the iterator therefore stops the observation, which is the
            // guarantee `StoreObservation` documents.
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Bytes the mirror occupies on disk, including the WAL and shared-memory files.
    ///
    /// Zero for an in-memory store. The storage panel adds this to `sum(byteSize)` rather than
    /// shelling out to `du`.
    public func fileSizeOnDisk(fileManager: FileManager = .default) -> Int64 {
        guard let path = dbQueue.path as String?, path != ":memory:" else { return 0 }
        return [path, path + "-wal", path + "-shm"].reduce(into: Int64(0)) { total, candidate in
            let attributes = try? fileManager.attributesOfItem(atPath: candidate)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}

/// Failures the caller is expected to handle differently from "the query was wrong".
public enum MailStoreError: Error, Sendable {
    /// SQLite cannot read the file. The mirror is rebuildable, so the app offers that rather
    /// than refusing to launch.
    ///
    /// The SQLite result code and message rather than GRDB's `DatabaseError`: the app catches
    /// this, and a public case carrying a GRDB type would put GRDB back in the app's link line
    /// (ADR-0029). Neither field can carry anything a user wrote — SQLite's message describes
    /// the file, not its contents.
    case unreadable(resultCode: Int32, message: String)

    /// A row was written and then could not be found by the key it was written under. Only
    /// a schema that has lost a uniqueness constraint can produce this, so it is a bug
    /// rather than a condition — it exists so the write path has no force unwrap in it.
    case rowVanished(table: String, remoteId: Int64)
}

extension DatabaseError {
    fileprivate var isUnreadableDatabase: Bool {
        resultCode == .SQLITE_CORRUPT || resultCode == .SQLITE_NOTADB
    }
}

/// `ValueObservation.start` behind a scheduler whose type is only known to be *a*
/// scheduler.
///
/// GRDB declares two `start` overloads, and the one taking a
/// `ValueObservationMainActorScheduler` is itself `@MainActor`. Passing `.mainActor`
/// directly selects it, which a nonisolated `makeAsyncIterator()` cannot call. An opaque
/// `some ValueObservationScheduler` is not known to conform to the main-actor protocol, so
/// only the nonisolated overload applies — and `.mainActor` still schedules the delivery
/// where `concurrency.md` says values arrive.
private func startTracking<Element: Sendable>(
    _ fetch: @escaping @Sendable (Database) throws -> Element,
    in reader: DatabaseQueue,
    scheduling scheduler: some ValueObservationScheduler,
    onError: @escaping @Sendable (any Error) -> Void,
    onChange: @escaping @Sendable (Element) -> Void
) -> AnyDatabaseCancellable {
    ValueObservation
        .tracking(fetch)
        .start(in: reader, scheduling: scheduler, onError: onError, onChange: onChange)
}

/// One logger for the package. Nothing here ever interpolates a subject, an address or a body:
/// identifiers and counts only, and `.public` is applied by hand where it is provably safe.
let storeLog = Logger(subsystem: "com.nextcloud.mail.macos", category: "store")
