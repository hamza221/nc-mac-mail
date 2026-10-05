// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import NCMailCore
public import NCMailNet
public import NCMailStore
internal import OSLog

/// Everything the app does with Nextcloud Files, and the only place it talks to Files.
///
/// Listings follow [ADR-0067](../../../../docs/decisions/0067-server-results-are-rows.md):
/// ``request(path:force:)`` returns at once, a WebDAV `PROPFIND` (Depth 1) runs, and the
/// answer is written into `filesListing` keyed `(loginId, path)`. The picker observes that
/// row and shows pending until it exists. A failure never overwrites a `ready` row, and
/// offline nothing is sent and nothing touched, so the picker keeps showing the last
/// listing it had.
///
/// The two actions that need an answer *now* — a public share link to paste, an image's
/// bytes to embed — are online-only commands in ADR-0068's shape: the caller awaits a
/// ``CommandOutcome`` and reads the result from a `serverResult` row
/// (``shareLinkKind``, ``imageKind``), never from a return value.
///
/// One per login, started by `AccountEngine`.
public actor FilesListingSync {
    /// A `ready` listing answers a request by itself for this long. Short, because a file
    /// added from the web or the desktop client must show up the next time the picker opens,
    /// and a Depth-1 PROPFIND costs one round trip (measured in the WS-33 report).
    public static let expiry: Int64 = 60
    /// `serverResult.kind` of a created public link, keyed by Files path; data `{"url": …}`.
    public static let shareLinkKind = "filesShareLink"
    /// `serverResult.kind` of an image staged for embedding, keyed by Files path; data
    /// `{"localPath": …, "mime": …}`.
    public static let imageKind = "filesImage"
    /// The web client's Insert image limit.
    public static let maximumImageBytes: Int64 = 10 * 1024 * 1024
    /// The web client's Insert image types.
    public static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/bmp", "image/webp"]

    static let properties: [DAVQualifiedName] = [
        .resourcetype,
        .getcontenttype,
        DAVQualifiedName(DAVQualifiedName.dav, "getcontentlength"),
        DAVQualifiedName(DAVQualifiedName.dav, "getlastmodified"),
        DAVQualifiedName(DAVQualifiedName.owncloud, "fileid"),
        DAVQualifiedName(DAVQualifiedName.owncloud, "size"),
    ]

    private let store: MailStore
    private let dav: DAVClient
    private let client: MailClient
    private let loginId: Int64
    private let stagingDirectory: URL
    private let now: @Sendable () -> Int64

    private var userId: String?
    private var conditions = MirrorConditions()
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// - Parameter stagingDirectory: where Insert image keeps the bytes it downloaded until
    ///   the editor has embedded them. Defaults to the (sandboxed) temporary directory.
    public init(
        store: MailStore,
        dav: DAVClient,
        client: MailClient,
        loginId: Int64,
        stagingDirectory: URL? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.store = store
        self.dav = dav
        self.client = client
        self.loginId = loginId
        self.stagingDirectory =
            stagingDirectory
            ?? FileManager.default.temporaryDirectory.appending(path: "FilesImages", directoryHint: .isDirectory)
        self.now = now
    }

    deinit {
        for task in inFlight.values { task.cancel() }
    }

    // MARK: - Listings

    /// Registers interest in one folder's listing and returns immediately.
    ///
    /// Nothing is sent while offline, while the same path is in flight, or while the row is
    /// younger than ``expiry`` (five minutes for a `failed` row).
    ///
    /// - Parameter force: ignore the expiry — the picker's Reload.
    public func request(path: String, force: Bool = false) {
        guard !conditions.isOffline else { return }
        let path = FilesPath.normalize(path)
        guard inFlight[path] == nil else { return }
        inFlight[path] = Task(priority: .userInitiated) {
            await self.fetch(path: path, force: force)
            self.finished(path)
        }
    }

    /// The path monitor, through the same door as the other actors (ADR-0031).
    public func apply(conditions newConditions: MirrorConditions) {
        conditions = newConditions
    }

    /// Waits for every listing in flight. For tests; a view never needs it.
    func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private func finished(_ path: String) {
        inFlight.removeValue(forKey: path)
    }

    private func fetch(path: String, force: Bool) async {
        let existing = try? await store.filesListing(path: path, loginId: loginId)
        let previous = existing.map(FilesListingState.init(record:))
        if !force, let existing, let previous {
            let age = now() - existing.fetchedAt
            let fresh =
                previous.entries == nil ? age < ServerResultKind.failureRetryAfter : age < Self.expiry
            if fresh { return }
        }

        let state: FilesListingState
        do {
            state = .ready(try await list(path: path))
        } catch is CancellationError {
            return
        } catch {
            let name = Self.describe(error)
            FilesLog.files.info("listing failed: \(name, privacy: .public)")
            // A stale listing beats an error, and offline is not the moment to lose one.
            if previous?.entries != nil { return }
            state = .failed(name)
        }
        do {
            try await store.upsert(
                filesListing: FilesListingRecord(
                    loginId: loginId, path: path, entriesJSON: try state.jsonText(), fetchedAt: now()))
        } catch {
            FilesLog.files.error("listing not written: \(Self.describe(error), privacy: .public)")
        }
    }

    /// One PROPFIND, folders first, then by name as Finder sorts.
    func list(path: String) async throws -> [FilesEntry] {
        let root = try await filesRoot()
        let folderURL = Self.url(of: path, under: root, isFolder: true)
        let resources = try await dav.propfind(folderURL, depth: .one, properties: Self.properties)
        let rootPath = root.path(percentEncoded: false)
        let folderPath = FilesPath.normalize(path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        var entries: [FilesEntry] = []
        for resource in resources {
            let absolute = dav.resolve(href: resource.href).path(percentEncoded: false)
            guard absolute.hasPrefix(rootPath) || absolute + "/" == rootPath else { continue }
            let relative = FilesPath.normalize(String(absolute.dropFirst(min(rootPath.count, absolute.count))))
            guard relative != folderPath, let name = FilesPath.components(relative).last else { continue }
            let isFolder = resource.isCollection
            let length = resource.property(DAVQualifiedName(DAVQualifiedName.dav, "getcontentlength"))?.text
            let ocSize = resource.property(DAVQualifiedName(DAVQualifiedName.owncloud, "size"))?.text
            let modified = resource.property(DAVQualifiedName(DAVQualifiedName.dav, "getlastmodified"))?.text
            entries.append(
                FilesEntry(
                    path: relative,
                    name: name,
                    isFolder: isFolder,
                    mime: isFolder ? nil : resource.property(.getcontenttype)?.text,
                    size: (length ?? ocSize).flatMap { Int64($0) },
                    modifiedAt: modified.flatMap { formatter.date(from: $0) }.map { Int64($0.timeIntervalSince1970) },
                    fileId: resource.property(DAVQualifiedName(DAVQualifiedName.owncloud, "fileid"))?.text
                        .flatMap { Int64($0) }
                ))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Share link

    /// Creates a public link share (`POST /ocs/v2.php/apps/files_sharing/api/v1/shares`,
    /// `shareType` 3) and writes its URL into the ``shareLinkKind`` row for `path`.
    ///
    /// Online-only: a link that will exist hours from now cannot be pasted into a message
    /// being written now. Each call creates a new share, as the web client does.
    public func createShareLink(path: String) async -> CommandOutcome {
        let path = FilesPath.normalize(path)
        do {
            let answer = try await client.post(.createShareLink, body: ShareLinkRequest(path: path))
            guard let url = answer.data.url, !url.isEmpty else {
                throw MailError.server(status: 200, message: nil)
            }
            try await writeResult(kind: Self.shareLinkKind, key: path, data: ["url": .string(url)])
            FilesLog.files.info("share link created")
            return .success
        } catch {
            FilesLog.files.error("share link failed: \(Self.describe(error), privacy: .public)")
            return .failure(Self.mailError(error))
        }
    }

    // MARK: - Insert image

    /// Downloads an image from Files into the staging directory and writes where it went
    /// into the ``imageKind`` row for its path, for the editor to embed as a `data:` URL.
    ///
    /// The type and size are enforced twice: from the listing before anything is sent, and
    /// from the bytes that arrived, because a listing can be a minute old.
    public func stageImage(_ entry: FilesEntry) async -> CommandOutcome {
        guard entry.isEmbeddableImage, let mime = entry.mime else {
            return .failure(.server(status: 415, message: nil))
        }
        do {
            let userId = try await resolveUserId()
            // Server-relative and escaped segment by segment: `Endpoint` takes the path as-is.
            let encodedPath =
                (["remote.php", "dav", "files", Endpoint<Data>.escape(userId)]
                + FilesPath.components(entry.path).map { Endpoint<Data>.escape($0) }).joined(separator: "/")
            let (data, _) = try await client.bytes(
                Endpoint<Data>(
                    name: "filesDownload", method: .get, base: .server, encodedPath: encodedPath, isRetryable: true)
            )
            guard Int64(data.count) <= Self.maximumImageBytes else {
                return .failure(.server(status: 413, message: nil))
            }
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let ext = (entry.name as NSString).pathExtension
            let file = stagingDirectory.appending(path: UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
            try data.write(to: file, options: .atomic)
            try await writeResult(
                kind: Self.imageKind,
                key: FilesPath.normalize(entry.path),
                data: ["localPath": .string(file.path(percentEncoded: false)), "mime": .string(mime)]
            )
            return .success
        } catch {
            FilesLog.files.error("image download failed: \(Self.describe(error), privacy: .public)")
            return .failure(Self.mailError(error))
        }
    }

    // MARK: - Plumbing

    /// `{server}/remote.php/dav/files/{user id}/`.
    private func filesRoot() async throws -> URL {
        let id = try await resolveUserId()
        return dav.davRoot.appending(path: "files", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
    }

    /// The user id comes from the principal, not the login name, which can be an email
    /// address the DAV tree does not use. Asked once per actor.
    private func resolveUserId() async throws -> String {
        if let userId { return userId }
        let principal = try await dav.currentUserPrincipal()
        guard let id = principal.path(percentEncoded: false).split(separator: "/").last.map(String.init) else {
            throw DAVError.invalidResponse("principal without a user id")
        }
        userId = id
        return id
    }

    static func url(of path: String, under root: URL, isFolder: Bool) -> URL {
        let components = FilesPath.components(path)
        var url = root
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            url = url.appending(path: component, directoryHint: isLast && !isFolder ? .notDirectory : .isDirectory)
        }
        return url
    }

    private func writeResult(kind: String, key: String, data: [String: AnyJSON]) async throws {
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId,
                kind: kind,
                key: key,
                payloadJSON: try ServerResultPayload.ready(.object(data)).jsonText(),
                fetchedAt: now()
            )
        )
    }

    // MARK: - Reading the result rows

    /// The public link a ``shareLinkKind`` row holds.
    public static func shareLinkURL(in record: ServerResultRecord) -> URL? {
        guard case .ready(let data) = try? ServerResultPayload(payloadJSON: record.payloadJSON),
            let text = data.objectValue?.string("url")
        else { return nil }
        return URL(string: text)
    }

    /// The staged file an ``imageKind`` row points at.
    public static func stagedImageURL(in record: ServerResultRecord) -> URL? {
        guard case .ready(let data) = try? ServerResultPayload(payloadJSON: record.payloadJSON),
            let path = data.objectValue?.string("localPath")
        else { return nil }
        return URL(filePath: path)
    }

    /// A short, content-free error name for the log and a `failed` row.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as DAVError:
            switch error {
            case .unauthorized: "unauthorized"
            case .forbidden: "forbidden"
            case .notFound: "notFound"
            case .transport: "transport"
            case .server(let status, _, _): "server(\(status))"
            default: "dav"
            }
        case let error as MailError: error.description
        default: describeSync(error)
        }
    }

    static func mailError(_ error: any Error) -> MailError {
        switch error {
        case let error as MailError: return error
        case let error as DAVError:
            switch error {
            case .unauthorized: return .unauthorized
            case .forbidden: return .forbidden
            case .notFound: return .notFound
            case .transport(let underlying): return .transport(underlying)
            case .server(let status, _, let message): return .server(status: status, message: message)
            default: return .server(status: 0, message: nil)
            }
        default: return .transport(error)
        }
    }
}

enum FilesLog {
    static let files = Logger(subsystem: "com.nextcloud.mail.macos", category: "files")
}
