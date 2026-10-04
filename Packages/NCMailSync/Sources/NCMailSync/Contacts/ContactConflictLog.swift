// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import OSLog

/// What a contact write's 412 recovery decided, kept for the session (ADR-0082).
///
/// Same-field conflicts resolve themselves — local wins — so they are not rows the user has
/// to act on; they are logged, here and to OSLog, so "my change overwrote a colleague's" can
/// be answered. A write that gave up is the queue's conflict row, and is recorded here too
/// so both outcomes are counted in one place.
public actor ContactConflictLog {
    public struct Entry: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// The server also changed these names; the local lines were kept.
            case localWon(properties: [String])
            /// The server changed an edited name *and* won the race twice: the write is
            /// parked as a conflict row in the queue.
            case gaveUp
            /// A delete that met a newer server copy and deleted it anyway.
            case deletedNewer
        }

        public var operationId: Int64
        public var addressBookId: Int64?
        public var contactId: Int64?
        public var outcome: Outcome
        public var at: Date
    }

    /// Bounded: this is a diagnostic, not a history.
    public static let capacity = 200

    public private(set) var entries: [Entry] = []

    public init() {}

    func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        switch entry.outcome {
        case .localWon(let properties):
            ContactsLog.contacts.notice(
                """
                contact write \(entry.operationId, privacy: .public): server also changed \
                \(properties.joined(separator: ","), privacy: .public); local kept
                """
            )
        case .gaveUp:
            ContactsLog.contacts.error(
                "contact write \(entry.operationId, privacy: .public): second 412, parked as a conflict")
        case .deletedNewer:
            ContactsLog.contacts.notice(
                "contact delete \(entry.operationId, privacy: .public): server copy was newer; deleted anyway")
        }
    }
}
