// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// A quick action as the §8.7 editor holds it, with the terminal-step rules.
///
/// A terminal step — Mark as spam, Move thread, Delete thread — takes the thread out of
/// the list, so nothing after it could run. Hence: at most one, always last, never moved;
/// once there, the add menu offers only the non-terminal steps and inserts them before it.
struct QuickActionDraft: Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        let id: UUID
        /// The server's step id (negative while a create is queued), nil for a step not
        /// saved yet.
        var remoteId: Int64?
        var name: String
        var tagRemoteId: Int64?
        var mailboxRemoteId: Int64?

        init(
            id: UUID = UUID(), remoteId: Int64? = nil, name: String, tagRemoteId: Int64? = nil,
            mailboxRemoteId: Int64? = nil
        ) {
            self.id = id
            self.remoteId = remoteId
            self.name = name
            self.tagRemoteId = tagRemoteId
            self.mailboxRemoteId = mailboxRemoteId
        }

        var isTerminal: Bool { QuickActionStep.isTerminal(name) }

        var isComplete: Bool {
            switch name {
            case QuickActionStep.applyTag: tagRemoteId != nil
            case QuickActionStep.moveThread: mailboxRemoteId != nil
            default: true
            }
        }
    }

    /// The server's quick action id (negative while its create is queued); nil for a new one.
    var remoteId: Int64?
    var name: String
    var steps: [Step]

    init(remoteId: Int64? = nil, name: String = "", steps: [Step] = []) {
        self.remoteId = remoteId
        self.name = name
        self.steps = steps
    }

    init(action: QuickActionRecord, steps records: [QuickActionStepRecord]) {
        self.init(
            remoteId: action.remoteId,
            name: action.name,
            steps: records.sorted { $0.position < $1.position }.map {
                Step(
                    remoteId: $0.remoteId, name: $0.name, tagRemoteId: $0.tagRemoteId,
                    mailboxRemoteId: $0.mailboxRemoteId)
            }
        )
    }

    /// The "Add another action" menu, in the web's order.
    static let allStepNames = [
        QuickActionStep.markAsSpam, QuickActionStep.applyTag, QuickActionStep.moveThread,
        QuickActionStep.deleteThread, QuickActionStep.markAsRead, QuickActionStep.markAsUnread,
        QuickActionStep.markAsImportant, QuickActionStep.markAsFavorite,
    ]

    static func title(of name: String) -> String {
        switch name {
        case QuickActionStep.markAsSpam: String(localized: "Mark as spam")
        case QuickActionStep.applyTag: String(localized: "Tag")
        case QuickActionStep.moveThread: String(localized: "Move thread")
        case QuickActionStep.deleteThread: String(localized: "Delete thread")
        case QuickActionStep.markAsRead: String(localized: "Mark as read")
        case QuickActionStep.markAsUnread: String(localized: "Mark as unread")
        case QuickActionStep.markAsImportant: String(localized: "Mark as important")
        case QuickActionStep.markAsFavorite: String(localized: "Mark as favorite")
        default: name
        }
    }

    var hasTerminalStep: Bool { steps.contains(where: \.isTerminal) }

    /// What "Add another action" offers now: everything, or the non-terminal steps once a
    /// terminal one is in place.
    var addableStepNames: [String] {
        hasTerminalStep ? Self.allStepNames.filter { !QuickActionStep.isTerminal($0) } : Self.allStepNames
    }

    /// Appends, or inserts before the terminal step. A second terminal step is refused.
    @discardableResult
    mutating func add(_ name: String) -> Step? {
        guard addableStepNames.contains(name) else { return nil }
        let step = Step(name: name)
        if let terminal = steps.firstIndex(where: \.isTerminal) {
            steps.insert(step, at: terminal)
        } else {
            steps.append(step)
        }
        return step
    }

    func canMove(_ id: Step.ID, by offset: Int) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == id }), !steps[index].isTerminal else { return false }
        let target = index + offset
        guard steps.indices.contains(target) else { return false }
        return !steps[target].isTerminal
    }

    /// Swaps with a neighbour. The terminal step neither moves nor is jumped over.
    mutating func move(_ id: Step.ID, by offset: Int) {
        guard canMove(id, by: offset), let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps.swapAt(index, index + offset)
    }

    @discardableResult
    mutating func remove(_ id: Step.ID) -> Step? {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return nil }
        return steps.remove(at: index)
    }

    /// Save is disabled until a name, one step, and every tag and folder chosen.
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !steps.isEmpty && steps.allSatisfy(\.isComplete)
    }

    /// The steps whose server row must be written: new ones, and saved ones whose order,
    /// tag or folder changed. `order` is 1-based, as the server stores it.
    func stepWrites(comparedTo saved: QuickActionDraft?) -> [(step: Step, order: Int)] {
        let before = Dictionary(
            (saved?.steps ?? []).enumerated().compactMap { index, step in
                step.remoteId.map { ($0, (step, index + 1)) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return steps.enumerated().compactMap { index, step in
            let order = index + 1
            guard let remoteId = step.remoteId, let (old, oldOrder) = before[remoteId] else {
                return (step, order)
            }
            let unchanged =
                oldOrder == order && old.tagRemoteId == step.tagRemoteId && old.mailboxRemoteId == step.mailboxRemoteId
            return unchanged ? nil : (step, order)
        }
    }
}
