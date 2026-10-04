// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import NCMailCore
public import NCMailNet
public import NCMailStore

/// Asks the server for a computed result because a view wants one, and writes the answer
/// into the store. [ADR-0067](../../../../docs/decisions/0067-server-results-are-rows.md).
///
/// ``request(kind:key:force:)`` returns as soon as the request is registered. The view
/// observes `serverResult` (`MailStore.observeServerResult(kind:key:loginId:)`) and shows
/// pending until the row exists; the row's ``ServerResultPayload`` says whether it holds an
/// answer, an "the server had nothing", or a failure. Nothing here hands a result back to a
/// caller, which is what keeps "the network only writes to the database" without
/// exceptions.
///
/// One per signed-in login: `serverResult` is keyed by `loginId`. WS-25 starts it with the
/// session.
public actor ServerResultFetcher {
    let store: MailStore
    let client: MailClient
    let identity: ServerIdentity
    let now: @Sendable () -> Int64

    private var loginId: Int64?
    // Internal, not private: the Smart Picker extension shares the door and the joins.
    var conditions = MirrorConditions()
    var inFlight: [String: Task<Void, Never>] = [:]

    public init(
        store: MailStore,
        client: MailClient,
        identity: ServerIdentity,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.store = store
        self.client = client
        self.identity = identity
        self.now = now
    }

    deinit {
        for task in inFlight.values { task.cancel() }
    }

    /// Registers interest in one result and returns immediately.
    ///
    /// Nothing is sent when the existing row is younger than the kind's
    /// ``ServerResultKind/expiry`` (at most fifteen minutes for an `empty` row, five for a
    /// `failed` one), when the same `(kind, key)` is already in flight, or while offline —
    /// offline, the last row stays exactly as it was.
    ///
    /// - Parameter force: ignore the expiry, for an explicit "regenerate".
    public func request(kind: ServerResultKind, key: String, force: Bool = false) {
        guard !conditions.isOffline else {
            MirrorLog.mirror.debug("server result \(kind.rawValue, privacy: .public) skipped: offline")
            return
        }
        let id = "\(kind.rawValue)|\(key)"
        guard inFlight[id] == nil else { return }
        inFlight[id] = Task(priority: .userInitiated) {
            await self.fetch(kind: kind, key: key, force: force)
            self.finished(id)
        }
    }

    /// The app shell's path monitor, through the same door as the other actors (ADR-0031).
    /// Going offline cancels nothing already sent; it stops new requests.
    public func apply(conditions newConditions: MirrorConditions) {
        conditions = newConditions
    }

    /// Waits for every request in flight. For tests and the live smoke run; a view never
    /// needs it, because the row arriving is the signal.
    func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    func finished(_ id: String) {
        inFlight.removeValue(forKey: id)
    }

    // MARK: - One request

    private func fetch(kind: ServerResultKind, key: String, force: Bool) async {
        let writer: ServerResultWriter
        do {
            writer = ServerResultWriter(store: store, loginId: try await resolveLoginId())
        } catch {
            MirrorLog.mirror.error("server result: login row unavailable: \(describeSync(error), privacy: .public)")
            return
        }
        if !force, await writer.isFresh(kind: kind, key: key, at: now()) { return }

        let payload: ServerResultPayload
        do {
            payload = try await answer(kind: kind, key: key, loginId: writer.loginId)
        } catch is CancellationError {
            return
        } catch {
            let name = describeSync(error)
            MirrorLog.mirror.info("server result \(kind.rawValue, privacy: .public) failed: \(name, privacy: .public)")
            payload = .failed(name)
        }
        do {
            try await writer.write(payload, kind: kind, key: key, at: now())
        } catch {
            MirrorLog.mirror.error(
                "server result \(kind.rawValue, privacy: .public) not written: \(describeSync(error), privacy: .public)"
            )
        }
    }

    private func answer(kind: ServerResultKind, key: String, loginId: Int64) async throws -> ServerResultPayload {
        switch kind {
        case .threadSummary:
            let message = try await remoteMessageId(key)
            return try readyOrEmpty(try await client.get(.threadSummary(messageId: message)).data)

        case .smartReply:
            let message = try await remoteMessageId(key)
            return try readyOrEmpty(try await client.get(.smartReply(messageId: message)).replies)

        case .itinerary:
            let message = try await remoteMessageId(key)
            return try readyOrEmpty(try await client.get(.itineraries(messageId: message)))

        case .eventData:
            let message = try await remoteMessageId(key)
            guard let event = try await client.get(.threadEventData(messageId: message)).data else { return .empty }
            return .ready(.object(["summary": event.summary.json, "description": event.description.json]))

        case .translation:
            return try await translate(key: key)

        case .autoComplete:
            let recipients = try await client.get(.autoComplete(term: key))
            let fetchedAt = now()
            try await store.replaceRecipientSuggestions(
                recipients.enumerated().map { position, recipient in
                    RecipientSuggestionRecord(
                        loginId: loginId,
                        term: key,
                        position: position,
                        email: recipient.email,
                        label: recipient.label,
                        source: recipient.source,
                        fetchedAt: fetchedAt
                    )
                },
                term: key,
                loginId: loginId
            )
            return .ready(.object(["count": .int(recipients.count)]))

        case .quota:
            guard let accountId = Int64(key), let account = try await store.account(id: accountId) else {
                throw ServerResultError.unknownKey
            }
            return quotaPayload(try await client.get(.quota(accountId: Int(account.remoteId))).data)

        case .followUp:
            let message = try await remoteMessageId(key)
            let check = try await client.post(.followUpCheck, body: FollowUpCheckRequest(messageIds: [message]))
            return .ready(.object(["wasFollowedUp": .bool(check.data.wasFollowedUp.contains(message))]))

        case .messageSource:
            let message = try await remoteMessageId(key)
            return .ready(.object(["source": .string(try await client.get(.messageSource(id: message)).source)]))

        case .sharees:
            return shareesPayload(try await client.get(.sharees(search: key)).data)

        case .teams:
            return try await refreshTeams(loginId: loginId)

        case .sharedItems:
            return try await sharedItems(with: key)
        }
    }

    /// Translates the stored body: the plain part when there is one, otherwise the
    /// sanitised HTML, which translation providers carry through markup intact. The body
    /// is read from the mirror, never re-downloaded — a message with no body yet fails the
    /// request and is retried once the backfill reaches it.
    private func translate(key: String) async throws -> ServerResultPayload {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, let messageId = Int64(parts[0]) else {
            throw ServerResultError.unknownKey
        }
        let target = parts[parts.count - 1]
        let source = parts.count == 3 ? parts[1] : nil
        guard let stored = try await store.body(messageId: messageId)?.body,
            let text = stored.plainBody ?? stored.html, !text.isEmpty
        else { throw ServerResultError.bodyNotMirrored }
        let response = try await client.post(
            .translate,
            body: TranslateRequest(text: text, fromLanguage: source, toLanguage: target)
        )
        guard let translated = response.data.text, !translated.isEmpty else { return .empty }
        return .ready(.object(["text": .string(translated), "from": response.data.from.json]))
    }

    private func remoteMessageId(_ key: String) async throws -> Int {
        guard let id = Int64(key), let message = try await store.message(id: id) else {
            throw ServerResultError.unknownKey
        }
        return Int(message.remoteId)
    }

    func resolveLoginId() async throws -> Int64 {
        if let loginId { return loginId }
        guard let id = try await store.ensureLogin(identity).id else { throw ServerResultError.unknownKey }
        loginId = id
        return id
    }
}

/// The quota row's data: `{"usage", "limit"}` in bytes (the server multiplies IMAP's KiB by
/// 1024 in `MailManager::getQuota`), a limit of 0 meaning the IMAP server set none.
func quotaPayload(_ quota: Quota) -> ServerResultPayload {
    .ready(.object(["usage": .int(quota.usage), "limit": .int(quota.limit)]))
}

/// Why a request never reached the server. Its description is the `error` a `failed` row
/// carries.
enum ServerResultError: Error, CustomStringConvertible {
    /// The key names no row: a message deleted since the view asked, or a malformed key.
    case unknownKey
    /// A translation asked for before the backfill downloaded the body.
    case bodyNotMirrored

    var description: String {
        switch self {
        case .unknownKey: "unknownKey"
        case .bodyNotMirrored: "bodyNotMirrored"
        }
    }
}

extension String? {
    var json: AnyJSON { map(AnyJSON.string) ?? .null }
}
