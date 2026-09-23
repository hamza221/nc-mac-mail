// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

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

    public init(text: String, scope: Scope = .all, flags: FlagFilter? = nil) {
        self.text = text
        self.scope = scope
        self.flags = flags
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

    /// The narrowings the message list already sorts by, so a search can carry them too.
    ///
    /// Three booleans and not an `OptionSet`: they are independent, they are all "only show
    /// me these", and a set would need a name for the empty case that means the same as nil.
    public struct FlagFilter: Sendable, Equatable, Hashable {
        public var unreadOnly: Bool
        public var starredOnly: Bool
        public var withAttachmentsOnly: Bool

        public init(unreadOnly: Bool = false, starredOnly: Bool = false, withAttachmentsOnly: Bool = false) {
            self.unreadOnly = unreadOnly
            self.starredOnly = starredOnly
            self.withAttachmentsOnly = withAttachmentsOnly
        }

        /// True when every flag is off, which is the same query as no filter at all.
        public var isEmpty: Bool {
            !unreadOnly && !starredOnly && !withAttachmentsOnly
        }
    }
}
