// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// Which files the picker lists. Folders always show, so the person can keep browsing.
enum FilesTypeFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case images
    case documents
    case media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All files"
        case .images: "Images"
        case .documents: "Documents"
        case .media: "Audio & video"
        }
    }

    func matches(_ entry: FilesEntry) -> Bool {
        if entry.isFolder { return true }
        let mime = entry.mime ?? ""
        switch self {
        case .all: return true
        // The Insert image set, so the Images filter never offers what cannot be embedded.
        case .images: return FilesListingSync.imageTypes.contains(mime)
        case .documents:
            return mime.hasPrefix("text/") || mime == "application/pdf" || mime.contains("document")
                || mime.contains("spreadsheet") || mime.contains("presentation") || mime.contains("msword")
                || mime.contains("ms-excel") || mime.contains("ms-powerpoint") || mime == "application/rtf"
        case .media: return mime.hasPrefix("audio/") || mime.hasPrefix("video/")
        }
    }
}

/// What the person picked: files, or one folder in "Choose a folder" mode.
enum FilesPickerChoice: Hashable, Sendable {
    case files([FilesEntry])
    /// Relative to the Files root, `/` for the root — the `targetPath` save-to-Files takes.
    case folder(path: String)
}

/// The picker's state: which folder it shows and that folder's `filesListing` row.
///
/// It reads the row and asks the engine for a fresher one; it never fetches. The row
/// arriving is the only signal (ADR-0067).
@MainActor
@Observable
final class FilesPickerModel {
    enum Content: Equatable {
        /// No row yet: the spinner.
        case pending
        case entries([FilesEntry])
        /// A `failed` row and nothing cached.
        case failed(String)
    }

    private(set) var path = FilesPath.root
    private(set) var content: Content = .pending
    /// When the shown listing was fetched; nil while pending.
    private(set) var fetchedAt: Date?

    @ObservationIgnored private let store: MailStore
    @ObservationIgnored private let loginId: Int64
    @ObservationIgnored private let sync: FilesListingSync?
    @ObservationIgnored private var observation: Task<Void, Never>?

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "files")

    init(store: MailStore, loginId: Int64, sync: FilesListingSync?) {
        self.store = store
        self.loginId = loginId
        self.sync = sync
    }

    /// Shows `path`: whatever is cached at once, then whatever the engine writes.
    func open(_ newPath: String) {
        let normalized = FilesPath.normalize(newPath)
        observation?.cancel()
        path = normalized
        content = .pending
        fetchedAt = nil
        let rows = store.observeFilesListing(path: normalized, loginId: loginId)
        observation = Task { [weak self] in
            do {
                for try await record in rows {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(record)
                }
            } catch {
                Self.logger.error("listing observation failed: \(String(describing: error), privacy: .public)")
            }
        }
        request(force: false)
    }

    /// Asks the engine for this folder again. Offline it sends nothing and the cache stays.
    func request(force: Bool) {
        guard let sync else { return }
        let path = path
        Task { await sync.request(path: path, force: force) }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Root first, current folder last; `id` is the folder's path.
    var breadcrumbs: [(path: String, title: String)] {
        var crumbs = [(path: FilesPath.root, title: "Home")]
        var walked = FilesPath.root
        for component in FilesPath.components(path) {
            walked = FilesPath.appending(component, to: walked)
            crumbs.append((walked, component))
        }
        return crumbs
    }

    /// The footer note while offline, or nil online.
    func offlineNote(isOffline: Bool) -> String? {
        guard isOffline else { return nil }
        guard let fetchedAt, case .entries = content else {
            return "Offline — this folder has not been loaded yet."
        }
        let time = fetchedAt.formatted(
            date: Calendar.current.isDateInToday(fetchedAt) ? .omitted : .abbreviated,
            time: .shortened)
        return "Offline — showing the listing from \(time)."
    }

    private func apply(_ record: FilesListingRecord?) {
        guard let record else {
            content = .pending
            fetchedAt = nil
            return
        }
        switch FilesListingState(record: record) {
        case .ready(let entries): content = .entries(entries)
        case .failed(let error): content = .failed(error)
        }
        fetchedAt = Date(timeIntervalSince1970: TimeInterval(record.fetchedAt))
    }
}
