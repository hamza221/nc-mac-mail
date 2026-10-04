// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailStore

/// One file or folder of a Files listing, as the picker draws it and the actions consume it.
///
/// `path` is relative to the user's Files root and always starts with `/` — the spelling
/// the server's attachment handler (`{"type":"cloud","fileName":…}`), the share API
/// (`{"path":…}`) and the save-to-Files routes (`{"targetPath":…}`) all take.
public struct FilesEntry: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var isFolder: Bool
    public var mime: String?
    /// Bytes; for a folder, the recursive total the server keeps in `oc:size`.
    public var size: Int64?
    /// Unix seconds.
    public var modifiedAt: Int64?
    public var fileId: Int64?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isFolder: Bool,
        mime: String? = nil,
        size: Int64? = nil,
        modifiedAt: Int64? = nil,
        fileId: Int64? = nil
    ) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.mime = mime
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileId = fileId
    }

    /// Whether Insert image takes it: the web client's five types, at most 10 MB.
    public var isEmbeddableImage: Bool {
        guard !isFolder, let mime, FilesListingSync.imageTypes.contains(mime) else { return false }
        return (size ?? 0) <= FilesListingSync.maximumImageBytes
    }

    /// The `draftAttachment` row that attaches this file from Files. The server copies the
    /// file into the message at send time (`AttachmentService::handleAttachments`, type
    /// `cloud`), so nothing is downloaded or uploaded here.
    public func draftAttachment(draftId: Int64) -> DraftAttachmentRecord {
        let payload: [String: String] = ["type": "cloud", "fileName": path]
        // Encoding a [String: String] cannot fail.
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return DraftAttachmentRecord(
            draftId: draftId,
            kind: "cloud",
            fileName: name,
            mime: mime,
            size: size,
            payloadJSON: json
        )
    }
}

/// What a `filesListing.entriesJSON` holds: ADR-0067's envelope, `{"status":"ready","data":
/// [FilesEntry]}` or `{"status":"failed","error":…}`. A failed row exists only where no
/// listing was ever fetched — a failure never overwrites a ready one.
public enum FilesListingState: Sendable, Equatable {
    case ready([FilesEntry])
    case failed(String)

    public init(record: FilesListingRecord) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(record.entriesJSON.utf8)) else {
            self = .failed("undecodable")
            return
        }
        if envelope.status == "ready" {
            self = .ready(envelope.data ?? [])
        } else {
            self = .failed(envelope.error ?? "unknown")
        }
    }

    public var entries: [FilesEntry]? {
        if case .ready(let entries) = self { return entries }
        return nil
    }

    func jsonText() throws -> String {
        let envelope =
            switch self {
            case .ready(let entries): Envelope(status: "ready", data: entries, error: nil)
            case .failed(let error): Envelope(status: "failed", data: nil, error: error)
            }
        return String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    }

    private struct Envelope: Codable {
        var status: String
        var data: [FilesEntry]?
        var error: String?
    }
}

/// Files paths, spelled one way: `/` for the root, `/A/B` below it, never a trailing slash.
public enum FilesPath {
    public static let root = "/"

    public static func normalize(_ path: String) -> String {
        let parts = components(path)
        return parts.isEmpty ? root : "/" + parts.joined(separator: "/")
    }

    /// `["A", "B"]` for `/A/B`; empty for the root.
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public static func parent(of path: String) -> String {
        normalize(components(path).dropLast().joined(separator: "/"))
    }

    public static func appending(_ name: String, to folder: String) -> String {
        normalize(normalize(folder) + "/" + name)
    }
}
