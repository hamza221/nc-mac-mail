// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog

/// Local-first recipient autocomplete for one login (ADR-0072), and the editor's `@` source.
///
/// Phase one answers from the mirror alone: the contacts index is queried per keystroke
/// (FTS5, every enabled book of the login, groups included), and the login's own identities
/// and every address of its mirrored mail sit in an in-memory index built by one aggregate
/// query. Phase two asks ``ServerResultFetcher`` for `/api/autoComplete` *after* phase one
/// was yielded and merges the `recipientSuggestion` rows as they land — this type never
/// awaits the network, it observes a table (ADR-0067).
final class RecipientSuggestionProvider: MentionProvider {
    /// Rows the list shows at most.
    static let limit = 20
    /// Contact-address rows read per keystroke before ranking. A one-letter term can match
    /// most of a large book; the next keystroke narrows it.
    static let contactRowLimit = 2_000
    /// The server is asked from this many characters on; one letter is noise to it too.
    static let serverMinimumTermLength = 2
    /// How old the in-memory index may get before a query rebuilds it in the background.
    static let indexLifetime: Duration = .seconds(300)

    let loginId: Int64
    private let store: MailStore
    private let fetcher: @MainActor () -> ServerResultFetcher?
    private let clock = ContinuousClock()

    private var index: LocalIndex?
    private var indexBuiltAt: ContinuousClock.Instant?
    private var indexTask: Task<LocalIndex, Never>?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "people")

    /// - Parameter fetcher: read at each server request rather than captured, because the
    ///   login's engine starts after the composer may already be open and stops at sign-out.
    init(store: MailStore, loginId: Int64, fetcher: @escaping @MainActor () -> ServerResultFetcher?) {
        self.store = store
        self.loginId = loginId
        self.fetcher = fetcher
    }

    convenience init(store: MailStore, loginId: Int64, fetcher: ServerResultFetcher?) {
        self.init(store: store, loginId: loginId, fetcher: { fetcher })
    }

    /// The provider for the login an account belongs to, with the login's live fetcher; nil
    /// when the account or its login is not in the mirror.
    static func make(session: AppSession, accountId: Int64) async -> RecipientSuggestionProvider? {
        guard let login = await PeopleLogin.resolve(store: session.store, accountId: accountId) else { return nil }
        let engine = session.engine
        let sessionId = login.sessionId
        return RecipientSuggestionProvider(
            store: session.store, loginId: login.loginId, fetcher: { engine.serverResults(sessionId: sessionId) })
    }

    /// Builds the in-memory index ahead of the first keystroke. Optional: the first query
    /// builds it otherwise.
    func prepare() async {
        _ = await currentIndex()
    }

    // MARK: - Queries

    /// Phase one only: what the mirror and the cached server rows for `term` say right now.
    func localSuggestions(matching term: String) async -> [RecipientSuggestion] {
        guard let local = await localInput(for: term) else { return [] }
        return RecipientRanking.rank(local, limit: Self.limit)
    }

    /// The local list first, then the same list merged with the server supplement every time
    /// its rows for this term change. Cancel the iterating task to stop.
    func suggestions(matching term: String) -> AsyncStream<[RecipientSuggestion]> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self, let local = await self.localInput(for: term) else {
                    continuation.yield([])
                    continuation.finish()
                    return
                }
                continuation.yield(RecipientRanking.rank(local, limit: Self.limit))

                let key = Self.serverKey(term)
                guard key.count >= Self.serverMinimumTermLength, !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                // Asked only now, after the local list is on screen. Offline the fetcher
                // sends nothing and the observation below still serves an earlier answer.
                if let fetcher = self.fetcher() {
                    await fetcher.request(kind: .autoComplete, key: key)
                }
                do {
                    for try await rows in self.store.observeRecipientSuggestions(term: key, loginId: self.loginId) {
                        var merged = local
                        merged.server = rows
                        continuation.yield(RecipientRanking.rank(merged, limit: Self.limit))
                    }
                } catch {
                    Self.logger.error(
                        "recipient suggestion observation stopped: \(String(describing: error), privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func mentionCandidates(matching query: String) async -> [MentionCandidate] {
        await localSuggestions(matching: query).compactMap { suggestion in
            guard let email = suggestion.email, !suggestion.isGroupLike else { return nil }
            return MentionCandidate(displayName: suggestion.displayName, email: email)
        }
    }

    /// The cache key the server answer is stored under: trimmed and lowercased, so `Ada` and
    /// `ada` share one row set.
    static func serverKey(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Local sources

    private func localInput(for text: String) async -> RecipientRanking.Input? {
        let term = RecipientTerm(text)
        guard !term.isEmpty else { return nil }
        let index = await currentIndex()
        var input = RecipientRanking.Input()
        input.lastSeen = index.lastSeen
        input.ownEmails = index.ownEmails
        input.identityMatches = index.identities.filter {
            term.matches(emailLowercased: $0.emailLower, words: $0.words)
        }
        .map(\.identity)
        input.mailMatches = index.addresses.filter { term.matches(emailLowercased: $0.emailLower, words: $0.words) }
            .map(\.statistic)
        do {
            input.contacts = try await store.contactSuggestions(
                matching: text, loginId: loginId, limit: Self.contactRowLimit)
            let groupIds = input.contacts.filter(\.isGroup).map(\.contactId)
            if !groupIds.isEmpty {
                for member in try await store.groupMemberAddresses(groupIds: groupIds) {
                    input.groupMembers[member.groupId, default: []].append(
                        RecipientAddress(email: member.email, label: member.displayName))
                }
            }
        } catch {
            Self.logger.error("contact suggestions unavailable: \(String(describing: error), privacy: .public)")
        }
        return input
    }

    /// The in-memory index, built on first use and rebuilt in the background once stale —
    /// a stale index keeps answering meanwhile, because a few minutes' lag in "how often" is
    /// invisible and a blocked keystroke is not.
    private func currentIndex() async -> LocalIndex {
        if let index, let builtAt = indexBuiltAt {
            if clock.now - builtAt > Self.indexLifetime, indexTask == nil { startIndexBuild() }
            return index
        }
        if indexTask == nil { startIndexBuild() }
        // Invariant: startIndexBuild() always sets indexTask, and only its own completion
        // below clears it.
        guard let task = indexTask else { return LocalIndex() }
        return await task.value
    }

    private func startIndexBuild() {
        let store = store
        let loginId = loginId
        indexTask = Task { @MainActor [weak self] in
            let built = await LocalIndex.build(store: store, loginId: loginId)
            self?.index = built
            self?.indexBuiltAt = self?.clock.now
            self?.indexTask = nil
            return built
        }
    }
}

extension RecipientSuggestion {
    /// A recipient that is not one person's address: a contact group, or a server group.
    fileprivate var isGroupLike: Bool {
        switch kind {
        case .group: true
        case .server(let source): source == "groups"
        default: false
        }
    }
}

/// The in-memory half of the local sources: own identities and mirrored-mail addresses,
/// pre-folded so a keystroke only compares strings.
private nonisolated struct LocalIndex: Sendable {
    struct IndexedIdentity: Sendable {
        var identity: OwnIdentity
        var emailLower: String
        var words: [String]
    }

    struct IndexedAddress: Sendable {
        var statistic: MailAddressStatistic
        var emailLower: String
        var words: [String]
    }

    var identities: [IndexedIdentity] = []
    var addresses: [IndexedAddress] = []
    var lastSeen: [String: Int64] = [:]
    var ownEmails: Set<String> = []

    static func build(store: MailStore, loginId: Int64) async -> LocalIndex {
        var index = LocalIndex()
        do {
            guard let login = try await store.logins().first(where: { $0.id == loginId }) else { return index }
            let accounts = try await store.accounts(identity: login.identity).sorted { $0.id < $1.id }
            for account in accounts {
                index.add(OwnIdentity(accountId: account.id, email: account.emailAddress, name: account.name))
                for alias in try await store.aliases(accountId: account.id) {
                    index.add(OwnIdentity(accountId: account.id, email: alias.email, name: alias.name ?? account.name))
                }
            }
            let statistics = try await store.mailAddressStatistics(accountIds: accounts.map(\.id))
            index.addresses.reserveCapacity(statistics.count)
            for statistic in statistics {
                let lower = statistic.email.lowercased()
                index.lastSeen[lower] = max(index.lastSeen[lower] ?? 0, statistic.lastSeenAt)
                index.addresses.append(
                    IndexedAddress(
                        statistic: statistic, emailLower: lower,
                        words: RecipientTerm.words((statistic.label ?? "") + " " + statistic.email)))
            }
        } catch {
            Logger(subsystem: "com.nextcloud.mail.macos", category: "people").error(
                "recipient index unavailable: \(String(describing: error), privacy: .public)")
        }
        return index
    }

    private mutating func add(_ identity: OwnIdentity) {
        let lower = identity.email.lowercased()
        ownEmails.insert(lower)
        identities.append(
            IndexedIdentity(
                identity: identity, emailLower: lower,
                words: RecipientTerm.words((identity.name ?? "") + " " + identity.email)))
    }
}
