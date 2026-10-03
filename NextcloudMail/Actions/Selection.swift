// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore

/// What a triage action acts on.
///
/// Local `message.id`s, never the server's. The queue copies each row's `remoteId` in as it
/// writes the operation, which is what lets an action survive the message being re-enumerated
/// under a new server id while it waits ([ADR-0033](../../docs/decisions/0033-accounts-have-a-local-identity.md)).
struct Selection: Equatable, Sendable {
    /// Whether one selected row stands for one message or for its whole thread.
    ///
    /// The threaded list draws one row per thread, so a row there is a conversation and `A`
    /// has to archive all of it ([user-stories.md](../../docs/product/user-stories.md) S-05).
    enum Scope: Equatable, Sendable {
        case messages
        case threads
    }

    /// In the list's order, newest first, because that is the order the selection advances in.
    var messageIds: [Int64]
    var scope: Scope

    init(messageIds: [Int64], scope: Scope = .messages) {
        self.messageIds = messageIds
        self.scope = scope
    }

    /// The ids the user chose, put into the order the rows are drawn in.
    ///
    /// `ids` rather than `rows`, and that is the whole reason this initialiser exists.
    /// `MessageListStore.selectedRows` is filtered against the observation window, so a row
    /// the user selected and then had pushed past the window's end by newly arrived mail is
    /// missing from it while `selection` still holds it. Archiving a selection of three and
    /// getting two is the bug this avoids; ids the window cannot place go on the end in id
    /// order rather than being dropped.
    init(ids: Set<Int64>, orderedBy rows: [MessageRow], scope: Scope) {
        var ordered = rows.map(\.id).filter(ids.contains)
        let placed = Set(ordered)
        ordered.append(contentsOf: ids.subtracting(placed).sorted())
        self.init(messageIds: ordered, scope: scope)
    }

    var isEmpty: Bool { messageIds.isEmpty }
    var count: Int { messageIds.count }

    /// The scope a list view implies: one row is one thread when the list is threaded.
    static func scope(for listView: ListView) -> Scope {
        listView == .threaded ? .threads : .messages
    }
}

/// Whether an action can run, and if not, the sentence that says why.
///
/// The reason is a string rather than an error case because it is read by a person, in a
/// tooltip and in a disabled menu item. "An account missing the special mailbox disables the
/// action with an explanation, not a greyed button with no reason" is the brief's wording and
/// the reason is the explanation.
enum TriageAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    var reason: String? {
        if case .unavailable(let text) = self { return text }
        return nil
    }
}
