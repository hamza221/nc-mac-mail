// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What the user is looking for, and where.
///
/// A value rather than a set of arguments because it is the identity of a live query: the
/// list restarts its observation when this changes and leaves it alone when it does not, so
/// `Equatable` here is what stops a redraw from reopening the database observation.
public struct SearchQuery: Sendable, Equatable, Hashable {
    /// Exactly what was typed. The translation to an FTS5 `MATCH` expression happens at the
    /// last possible moment, in ``FTS5MatchExpression``, so nothing stores a half-escaped
    /// string that could be escaped twice.
    public var text: String
    public var scope: Scope
    public var flags: FlagFilter?
    /// The "Search parameters" sheet's fields. Empty by default, which adds nothing.
    public var parameters: Parameters

    public init(text: String, scope: Scope = .all, flags: FlagFilter? = nil, parameters: Parameters = Parameters()) {
        self.text = text
        self.scope = scope
        self.flags = flags
        self.parameters = parameters
    }

    /// True when there is something to search for: a term of at least two characters in the
    /// field, the Subject or the Body, or any filter switched on.
    ///
    /// False is the "empty field" answer: the store returns no rows for it rather than every
    /// message, and the app shows the mailbox instead of a search.
    public var hasCriteria: Bool {
        matchExpression != nil || !(flags?.isEmpty ?? true) || parameters.hasStructuredCriteria
    }

    /// The one FTS5 expression for the field, the Subject and the Body, or nil when none of
    /// them holds a usable term.
    var matchExpression: String? {
        FTS5MatchExpression.build([
            (text, nil),
            (parameters.subject, .subject),
            (parameters.body, .body),
        ])
    }

    /// The two scopes [ux-spec.md](../../../../docs/product/ux-spec.md#search) puts in the
    /// control, plus the per-account one the settings and storage screens can ask for.
    ///
    /// `.all` spans accounts. That is not an oversight: the mirror is one database holding
    /// every signed-in account, and a person looking for a message does not always remember
    /// which address it arrived at.
    ///
    /// Unsubscribed mailboxes are not mirrored ([ADR-0007](../../../../docs/decisions/0007-subscribed-mailboxes-only.md)),
    /// so they hold no rows to find until someone opens them. No scope filters them out —
    /// a message that reached the mirror is findable wherever it sits.
    public enum Scope: Sendable, Equatable, Hashable {
        case mailbox(Int64)
        case account(Int64)
        case all
    }

    /// The yes/no narrowings: the chips and the sheet's toggles.
    ///
    /// Booleans and not an `OptionSet`: they are independent, they are all "only show me
    /// these", and a set would need a name for the empty case that means the same as nil.
    public struct FlagFilter: Sendable, Equatable, Hashable {
        public var unreadOnly: Bool
        /// "Favorite" in the sheet: the IMAP `\Flagged` star.
        public var starredOnly: Bool
        public var withAttachmentsOnly: Bool
        /// The server's importance classification (`$label1` / `isImportant`).
        public var importantOnly: Bool
        /// The server's `mentionsMe` flag.
        public var mentionsMeOnly: Bool
        /// A `To:` recipient is the message's account address or one of that account's
        /// aliases. Compared case-insensitively; `Cc:` and `Bcc:` do not count.
        public var toMeOnly: Bool

        public init(
            unreadOnly: Bool = false,
            starredOnly: Bool = false,
            withAttachmentsOnly: Bool = false,
            importantOnly: Bool = false,
            mentionsMeOnly: Bool = false,
            toMeOnly: Bool = false
        ) {
            self.unreadOnly = unreadOnly
            self.starredOnly = starredOnly
            self.withAttachmentsOnly = withAttachmentsOnly
            self.importantOnly = importantOnly
            self.mentionsMeOnly = mentionsMeOnly
            self.toMeOnly = toMeOnly
        }

        /// True when every flag is off, which is the same query as no filter at all.
        public var isEmpty: Bool {
            !unreadOnly && !starredOnly && !withAttachmentsOnly && !importantOnly && !mentionsMeOnly && !toMeOnly
        }
    }

    /// The sheet's valued fields.
    ///
    /// Different fields combine with AND; the values inside one list field combine with OR —
    /// "to Alice or Bob", "tagged Work or Family" — which is how the server's own search
    /// reads them. Addresses match exactly and case-insensitively against the mirrored
    /// envelope, so `Alice@Example.org` and `alice@example.org` are the same filter.
    public struct Parameters: Sendable, Equatable, Hashable {
        /// Words that must appear in the subject. Same term rules as the field.
        public var subject: String
        /// Words that must appear in the downloaded body. Same term rules as the field.
        public var body: String
        /// Sent at or after this instant, unix seconds.
        public var sentAfter: Int64?
        /// Sent strictly before this instant, unix seconds. Half-open, so a "to" day passes
        /// the start of the following day and nothing on a day boundary is counted twice.
        public var sentBefore: Int64?
        /// The sender. One address at most — the type is what enforces the rule.
        public var from: String?
        public var to: [String]
        public var cc: [String]
        public var bcc: [String]
        /// Tag IMAP labels (`$label1`, `work`), matched across accounts by label.
        public var tags: [String]

        public init(
            subject: String = "",
            body: String = "",
            sentAfter: Int64? = nil,
            sentBefore: Int64? = nil,
            from: String? = nil,
            to: [String] = [],
            cc: [String] = [],
            bcc: [String] = [],
            tags: [String] = []
        ) {
            self.subject = subject
            self.body = body
            self.sentAfter = sentAfter
            self.sentBefore = sentBefore
            self.from = from
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.tags = tags
        }

        /// True when every field is empty.
        public var isEmpty: Bool {
            FTS5MatchExpression.build([(subject, .subject), (body, .body)]) == nil && !hasStructuredCriteria
        }

        /// Whether a non-text field narrows the result: a date bound, an address or a tag.
        var hasStructuredCriteria: Bool {
            sentAfter != nil || sentBefore != nil || Self.normalized(from) != nil
                || !Self.normalized(to).isEmpty || !Self.normalized(cc).isEmpty
                || !Self.normalized(bcc).isEmpty || !Self.normalized(tags).isEmpty
        }

        /// Trimmed, empties dropped, duplicates dropped in first-seen order — the values the
        /// query binds, so `[" a@x ", "A@x"]` binds one address.
        static func normalized(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.compactMap(normalized).filter { seen.insert($0.lowercased()).inserted }
        }

        static func normalized(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
    }
}
