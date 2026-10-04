// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore
public import NCMailStore

/// The families of `serverResult` row (ADR-0067) and the key each one is filed under.
///
/// Keys are built only through the static helpers below, so the actor writing a row and
/// the view observing it cannot disagree about a format.
public enum ServerResultKind: String, Sendable, CaseIterable {
    /// `GET /api/thread/{id}/summary`. Key: local message id.
    case threadSummary
    /// `GET /api/messages/{id}/smartreply`. Key: local message id.
    case smartReply
    /// `POST /ocs/v2.php/translation/translate` over the stored body. Key:
    /// ``translationKey(messageId:to:)``.
    case translation
    /// `GET /api/messages/{id}/itineraries`. Key: local message id.
    case itinerary
    /// `GET /api/thread/{id}/eventdata`. Key: local message id.
    case eventData
    /// `GET /api/autoComplete?term=`; the suggestions are in `recipientSuggestion`, this row
    /// says when they were fetched and whether the fetch worked. Key: the term.
    case autoComplete
    /// `GET /api/accounts/{id}/quota`. Key: local account id.
    case quota
    /// `POST /api/follow-up/check-message-ids`. Key: local message id; data
    /// `{"wasFollowedUp": Bool}`.
    case followUp
    /// `GET /api/messages/{id}/source`. Key: local message id; data `{"source": String}`.
    case messageSource

    /// How long a `ready` or `empty` row answers a request without asking again, in
    /// seconds. Each kind's owner set it from how often the answer can change.
    public var expiry: Int64 {
        switch self {
        case .threadSummary, .eventData: 7 * 86_400
        case .smartReply: 86_400
        // A body never changes once delivered, so neither does what it says.
        case .translation, .itinerary, .messageSource: 30 * 86_400
        case .autoComplete, .quota: 3_600
        // Asked only while the follow-up section is on screen, and the whole point is to
        // notice a reply as soon as it lands.
        case .followUp: 0
        }
    }

    /// A `failed` row stops looking fresh after this long, so a view re-requesting after a
    /// failure gets one retry per five minutes and never a request loop.
    public static let failureRetryAfter: Int64 = 300

    public static func messageKey(_ messageId: Int64) -> String { String(messageId) }

    public static func accountKey(_ accountId: Int64) -> String { String(accountId) }

    /// `<local message id>:<target language>`, plus the source language in the middle when
    /// the user picked one rather than letting the server detect it.
    public static func translationKey(messageId: Int64, to target: String, from source: String? = nil) -> String {
        guard let source else { return "\(messageId):\(target)" }
        return "\(messageId):\(source):\(target)"
    }
}

/// What a `serverResult.payloadJSON` holds: `{"status": "ready"|"empty"|"failed", …}`.
///
/// Three states rather than "a row exists": a view needs to stop its pending indicator when
/// the server answered "nothing" (the 204 of an instance with no LLM provider) or when the
/// request failed, and to tell those apart from an answer.
public enum ServerResultPayload: Sendable, Equatable {
    /// The server's answer, as JSON, under `data`.
    case ready(AnyJSON)
    /// The server answered and had nothing to say.
    case empty
    /// The request failed; the associated value is a short error name, never a message
    /// body or anything user-supplied.
    case failed(String)

    public init(payloadJSON: String) throws {
        let fields = try JSONDecoder().decode(AnyJSON.self, from: Data(payloadJSON.utf8)).objectValue ?? [:]
        switch fields.string("status") {
        case "ready": self = .ready(fields["data"] ?? .null)
        case "empty": self = .empty
        default: self = .failed(fields.string("error") ?? "unknown")
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    func jsonText() throws -> String {
        let object: [String: AnyJSON] =
            switch self {
            case .ready(let data): ["status": .string("ready"), "data": data]
            case .empty: ["status": .string("empty")]
            case .failed(let error): ["status": .string("failed"), "error": .string(error)]
            }
        return try MirrorMapping.jsonText(AnyJSON.object(object))
    }
}

/// The one place a `serverResult` row is written, so the fetcher and the state mirror apply
/// the same rule: a failure never overwrites an answer.
struct ServerResultWriter: Sendable {
    let store: MailStore
    let loginId: Int64

    func write(_ payload: ServerResultPayload, kind: ServerResultKind, key: String, at now: Int64) async throws {
        if case .failed = payload,
            let existing = try await store.serverResult(kind: kind.rawValue, key: key, loginId: loginId),
            let previous = try? ServerResultPayload(payloadJSON: existing.payloadJSON), previous.isReady
        {
            // A stale answer beats an error, and offline is not the moment to lose one.
            return
        }
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId,
                kind: kind.rawValue,
                key: key,
                payloadJSON: try payload.jsonText(),
                fetchedAt: now
            )
        )
    }

    /// Whether the row for `(kind, key)` is young enough to answer a request by itself.
    func isFresh(kind: ServerResultKind, key: String, at now: Int64) async -> Bool {
        guard
            let row = try? await store.serverResult(kind: kind.rawValue, key: key, loginId: loginId),
            let payload = try? ServerResultPayload(payloadJSON: row.payloadJSON)
        else { return false }
        let age = now - row.fetchedAt
        if case .failed = payload { return age < ServerResultKind.failureRetryAfter }
        return age < kind.expiry
    }
}

/// `ready` with the answer, or `empty` when the server sent nothing.
func readyOrEmpty(_ value: some Encodable) throws -> ServerResultPayload {
    let json = try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(value))
    switch json {
    case .null: return .empty
    case .array(let items) where items.isEmpty: return .empty
    case .string(let text) where text.isEmpty: return .empty
    default: return .ready(json)
    }
}
