// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreSpotlight
import Foundation
import NCMailStore
import OSLog
import UniformTypeIdentifiers

/// One Spotlight item, as plain values: what ``SpotlightIndexer`` diffs and what a
/// ``SpotlightIndexing`` turns into a `CSSearchableItem`.
nonisolated struct SpotlightEntry: Equatable, Sendable {
    enum Kind: String, Sendable {
        case message
        case contact

        var domain: String {
            switch self {
            case .message: "messages"
            case .contact: "contacts"
            }
        }
    }

    var kind: Kind
    var localId: Int64
    var title: String
    var detail: String?
    var people: [String]
    var emails: [String]
    var date: Date?

    var identifier: String { SpotlightIdentifier.make(kind, localId) }
}

/// `message:<local id>` and `contact:<local id>`, the `uniqueIdentifier` a Spotlight result
/// comes back with (`CSSearchableItemActivityIdentifier`).
nonisolated enum SpotlightIdentifier {
    static func make(_ kind: SpotlightEntry.Kind, _ id: Int64) -> String { "\(kind.rawValue):\(id)" }

    static func link(for identifier: String) -> SystemLink? {
        let parts = identifier.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = Int64(parts[1]) else { return nil }
        switch SpotlightEntry.Kind(rawValue: String(parts[0])) {
        case .message: return .message(id)
        case .contact: return .contact(id)
        case nil: return nil
        }
    }
}

/// The index the indexer writes to. The real one is ``CoreSpotlightIndex``; tests use an
/// in-memory one, because what is worth testing is which items are written and deleted
/// when, not that `CSSearchableIndex` stores them.
nonisolated protocol SpotlightIndexing: Sendable {
    func upsert(_ entries: [SpotlightEntry]) async throws
    func delete(identifiers: [String]) async throws
    func deleteAll(domain: String) async throws
}

/// `CSSearchableIndex.default()`. The app is sandboxed, which is all the index needs; no
/// entitlement is involved.
nonisolated struct CoreSpotlightIndex: SpotlightIndexing {
    func upsert(_ entries: [SpotlightEntry]) async throws {
        let items = entries.map(Self.item)
        try await CSSearchableIndex.default().indexSearchableItems(items)
    }

    func delete(identifiers: [String]) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
    }

    func deleteAll(domain: String) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }

    private static func item(_ entry: SpotlightEntry) -> CSSearchableItem {
        let attributes: CSSearchableItemAttributeSet
        switch entry.kind {
        case .message:
            attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
            attributes.subject = entry.title
            attributes.authorNames = entry.people
            attributes.authorEmailAddresses = entry.emails
            attributes.contentCreationDate = entry.date
        case .contact:
            attributes = CSSearchableItemAttributeSet(contentType: .contact)
            attributes.emailAddresses = entry.emails
        }
        attributes.title = entry.title
        attributes.contentDescription = entry.detail
        attributes.displayName = entry.title
        return CSSearchableItem(
            uniqueIdentifier: entry.identifier, domainIdentifier: entry.kind.domain, attributeSet: attributes)
    }
}

/// Keeps Spotlight equal to a window of the mirror (ADR-0099): the newest
/// ``messageLimit`` messages across every mailbox, and every contact card.
///
/// Fed by store observations (`SystemIntegration`), it diffs each value against what it
/// last wrote and sends Spotlight only the difference: an item whose indexed fields changed
/// is rewritten, an item that left the window — deleted, moved past the limit, signed out —
/// is deleted. A flag change, which Spotlight does not show, writes nothing.
///
/// The first value of each domain replaces the domain outright, so items from a previous
/// launch that are no longer in the mirror do not survive.
actor SpotlightIndexer {
    static let messageLimit = 5_000
    private static let batch = 500

    private let index: any SpotlightIndexing
    private var messages: [String: SpotlightEntry]?
    private var contactRecords: [Int64: [Int64: ContactRecord]] = [:]
    private var contacts: [Int64: [String: SpotlightEntry]] = [:]
    private var contactsReset = false

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "spotlight")

    init(index: any SpotlightIndexing) {
        self.index = index
    }

    func updateMessages(_ rows: [MessageRow]) async {
        let next = Dictionary(
            rows.prefix(Self.messageLimit).map { row in
                let entry = Self.entry(for: row)
                return (entry.identifier, entry)
            },
            uniquingKeysWith: { first, _ in first })
        if messages == nil {
            await run { try await index.deleteAll(domain: SpotlightEntry.Kind.message.domain) }
            messages = [:]
        }
        await apply(old: messages ?? [:], new: next)
        messages = next
    }

    /// One login's cards. `emails` is asked only for cards that are new or changed.
    func updateContacts(
        _ records: [ContactRecord], loginId: Int64, emails: @Sendable (Int64) async -> [String]
    ) async {
        if !contactsReset {
            await run { try await index.deleteAll(domain: SpotlightEntry.Kind.contact.domain) }
            contactsReset = true
        }
        let previousRecords = contactRecords[loginId] ?? [:]
        let previous = contacts[loginId] ?? [:]
        var nextRecords: [Int64: ContactRecord] = [:]
        var next: [String: SpotlightEntry] = [:]
        for record in records where !record.isGroup {
            guard let id = record.id else { continue }
            nextRecords[id] = record
            let identifier = SpotlightIdentifier.make(.contact, id)
            if previousRecords[id] == record, let unchanged = previous[identifier] {
                next[identifier] = unchanged
            } else {
                next[identifier] = Self.entry(for: record, id: id, emails: await emails(id))
            }
        }
        await apply(old: previous, new: next)
        contactRecords[loginId] = nextRecords
        contacts[loginId] = next
    }

    /// A login signed out: its cards leave Spotlight with it.
    func removeContacts(loginId: Int64) async {
        guard let previous = contacts.removeValue(forKey: loginId) else { return }
        contactRecords[loginId] = nil
        await apply(old: previous, new: [:])
    }

    private func apply(old: [String: SpotlightEntry], new: [String: SpotlightEntry]) async {
        let deleted = old.keys.filter { new[$0] == nil }
        let changed = new.values.filter { old[$0.identifier] != $0 }
        for chunk in deleted.chunked(Self.batch) {
            await run { try await index.delete(identifiers: chunk) }
        }
        for chunk in changed.chunked(Self.batch) {
            await run { try await index.upsert(chunk) }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            Self.logger.error("spotlight write failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func entry(for row: MessageRow) -> SpotlightEntry {
        let subject = row.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SpotlightEntry(
            kind: .message,
            localId: row.id,
            title: subject.isEmpty ? String(localized: "No subject") : subject,
            detail: row.previewText,
            people: [row.senderName ?? row.senderEmail].compactMap { $0 },
            emails: [row.senderEmail].compactMap { $0 },
            date: Date(timeIntervalSince1970: TimeInterval(row.sentAt))
        )
    }

    nonisolated static func entry(for record: ContactRecord, id: Int64, emails: [String]) -> SpotlightEntry {
        let given = [record.givenName, record.familyName].compactMap { $0 }.joined(separator: " ")
        let name = [record.displayName, given, record.nickname, record.organization, emails.first]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return SpotlightEntry(
            kind: .contact,
            localId: id,
            title: name ?? String(localized: "No name"),
            detail: record.organization,
            people: [],
            emails: emails,
            date: nil
        )
    }
}

extension Collection {
    fileprivate nonisolated func chunked(_ size: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        var result: [[Element]] = []
        var start = startIndex
        while start != endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[start..<end]))
            start = end
        }
        return result
    }
}
