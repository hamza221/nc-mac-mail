// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import GRDB
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
    /// - Throws: ``MailStoreError/unreadable(_:)`` when SQLite says the file is not a database
    ///   it can read. That case is recoverable by deleting and re-mirroring, which is why it is
    ///   distinguishable from every other failure rather than folded into `DatabaseError`.
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
            throw MailStoreError.unreadable(error)
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

    public func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbQueue.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbQueue.write(block)
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
    case unreadable(DatabaseError)
}

extension DatabaseError {
    fileprivate var isUnreadableDatabase: Bool {
        resultCode == .SQLITE_CORRUPT || resultCode == .SQLITE_NOTADB
    }
}

/// One logger for the package. Nothing here ever interpolates a subject, an address or a body:
/// identifiers and counts only, and `.public` is applied by hand where it is provably safe.
let storeLog = Logger(subsystem: "com.nextcloud.mail.macos", category: "store")
