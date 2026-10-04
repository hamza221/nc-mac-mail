// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore

/// What the content column lists: the selections of `SidebarSelection` that are lists of
/// messages.
enum MessageListSource: Hashable, Sendable {
    case mailbox(Int64)
    case unifiedInbox
    case priorityInbox
    case favorites(inboxId: Int64)

    /// Nil for a selection that is not a message list (the outbox, contacts) and for none.
    init?(_ selection: SidebarSelection?) {
        switch selection {
        case .mailbox(let id): self = .mailbox(id)
        case .unifiedInbox: self = .unifiedInbox
        case .priorityInbox: self = .priorityInbox
        case .favorites(let inboxId): self = .favorites(inboxId: inboxId)
        case .outbox, .contacts, nil: return nil
        }
    }

    /// The one mailbox whose mirror state decides the empty screens. The merged lists have
    /// none: an empty Unified inbox is simply empty.
    var mailboxId: Int64? {
        if case .mailbox(let id) = self { id } else { nil }
    }

    var title: String? {
        switch self {
        case .mailbox: nil
        case .unifiedInbox: String(localized: "All inboxes")
        case .priorityInbox: String(localized: "Priority inbox")
        case .favorites: String(localized: "Favorites")
        }
    }

    /// Whether the list spans every account's Inbox, and so needs their ids.
    var needsInboxes: Bool {
        self == .unifiedInbox || self == .priorityInbox
    }
}

/// One live query of a list and how its rows are drawn.
struct MessageListPlan: Equatable, Sendable {
    let bucket: MessageListBucket
    let query: MessageListQuery
    /// Date groups as section headers, which the web client draws for whole lists and never
    /// inside Priority inbox's or the favorites' sections.
    let isDateGrouped: Bool

    /// How long a message waits for an answer before it shows under Follow up: the web
    /// client's `end:` of four days ago (`MailboxThread.vue`, `followUpQuery`).
    static let followUpAfter: Int64 = 4 * 86_400
    /// The tag the server sets on a sent message it wants a reply to.
    static let followUpLabel = "$follow_up"

    /// The sections a source is drawn in, top to bottom (ux-spec.md, WS-29).
    ///
    /// Pure, so the section rules are tested without a database. `inboxIds` are every
    /// account's Inbox; with none, the merged lists have no plan at all rather than a query
    /// over every mailbox, which is what an empty id list means to the store.
    static func plans(
        for source: MessageListSource,
        inboxIds: [Int64],
        preferences: MessageListPreferences,
        now: Int64
    ) -> [MessageListPlan] {
        switch source {
        case .mailbox(let id):
            return favoritesUp(mailboxIds: [id], preferences: preferences)
        case .unifiedInbox:
            guard !inboxIds.isEmpty else { return [] }
            return favoritesUp(mailboxIds: inboxIds, preferences: preferences)
        case .favorites(let inboxId):
            return [
                MessageListPlan(
                    bucket: .all, query: MessageListQuery(mailboxIds: [inboxId], isFlagged: true), isDateGrouped: true)
            ]
        case .priorityInbox:
            guard !inboxIds.isEmpty else { return [] }
            var plans: [MessageListPlan] = []
            // With favorites on top the starred messages are shown once, in Favorites, and
            // left out of the sections below — the web's `not:starred`.
            let starred: Bool? = preferences.favoritesOnTop ? false : nil
            if preferences.favoritesOnTop {
                plans.append(
                    MessageListPlan(
                        bucket: .favorites, query: MessageListQuery(mailboxIds: inboxIds, isFlagged: true),
                        isDateGrouped: false))
            }
            if preferences.followUpReminders {
                plans.append(
                    MessageListPlan(
                        bucket: .followUp,
                        // Every mailbox: the tag lands on the sent copy.
                        query: MessageListQuery(
                            mailboxIds: [], tagImapLabel: followUpLabel, sentAtOrBefore: now - followUpAfter),
                        isDateGrouped: false))
            }
            plans.append(
                MessageListPlan(
                    bucket: .important,
                    query: MessageListQuery(mailboxIds: inboxIds, isFlagged: starred, isImportant: true),
                    isDateGrouped: false))
            plans.append(
                MessageListPlan(
                    bucket: .other,
                    query: MessageListQuery(mailboxIds: inboxIds, isFlagged: starred, isImportant: false),
                    isDateGrouped: false))
            return plans
        }
    }

    private static func favoritesUp(mailboxIds: [Int64], preferences: MessageListPreferences) -> [MessageListPlan] {
        guard preferences.favoritesOnTop else {
            return [MessageListPlan(bucket: .all, query: MessageListQuery(mailboxIds: mailboxIds), isDateGrouped: true)]
        }
        return [
            MessageListPlan(
                bucket: .favorites, query: MessageListQuery(mailboxIds: mailboxIds, isFlagged: true),
                isDateGrouped: false),
            MessageListPlan(
                bucket: .all, query: MessageListQuery(mailboxIds: mailboxIds, isFlagged: false), isDateGrouped: true),
        ]
    }
}
