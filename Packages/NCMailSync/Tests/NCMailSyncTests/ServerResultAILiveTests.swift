// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// The AI rows against a live server with LLM processing on: a real inbox message's smart
/// replies, thread summary and event data land as `ready` rows with the server's content,
/// and an `empty` row left over from when the admin had processing off is asked again and
/// replaced.
///
/// Off by default, like every live test: it opens sockets, and each answer costs the
/// instance an LLM call. Needs `mail.llm_processing` on and a text-to-text provider.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --build-system native --filter ServerResultAILive
/// ```
@Suite("AI server results against a live server", .serialized)
struct ServerResultAILiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR"]

    private struct Live {
        let store: MailStore
        let fetcher: ServerResultFetcher
        let loginId: Int64
        /// The newest inbox message, and the newest one in a reply chain (subject "Re: …").
        let newest: MessageRow
        let reply: MessageRow

        static func open() async throws -> Live {
            let environment = ProcessInfo.processInfo.environment
            guard
                let raw = environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
                let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
            else { throw MirrorLiveMeasurementTests.LiveError.missingEnvironment }

            let store = try MailStore.inMemory()
            let client = MailClient(
                server: server,
                credentials: BasicCredentials(loginName: user, appPassword: password),
                clientVersion: "measurement"
            )
            let identity = ServerIdentity(serverURL: server, loginName: user)
            let account = try #require(
                try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity).first)
            // Envelopes only: the AI routes are keyed by the server id, not by a mirrored body.
            let coordinator = MirrorCoordinator(store: store, client: client, accountId: account.id)
            await coordinator.apply(conditions: MirrorConditions(isExpensive: true))
            await coordinator.start()
            await coordinator.awaitCurrentRun()

            let inbox = try #require(
                try await store.mailboxes(accountId: account.id).first { $0.specialRole?.lowercased() == "inbox" })
            let rows = try await store.messages(mailboxId: inbox.id, view: .flat, range: 0..<50)
            return Live(
                store: store,
                fetcher: ServerResultFetcher(store: store, client: client, identity: identity),
                loginId: try #require(try await store.ensureLogin(identity).id),
                newest: try #require(rows.first),
                reply: try #require(rows.first { $0.subject?.hasPrefix("Re:") == true })
            )
        }

        func payload(_ kind: ServerResultKind, _ key: String) async throws -> ServerResultPayload? {
            guard let row = try await store.serverResult(kind: kind.rawValue, key: key, loginId: loginId)
            else { return nil }
            return try ServerResultPayload(payloadJSON: row.payloadJSON)
        }

        /// Writes the row a session with LLM processing off left behind: `empty`, as old as
        /// the kind's `ready` expiry allows, which the old policy treated as fresh.
        func leaveStaleEmpty(_ kind: ServerResultKind, _ key: String) async throws {
            try await store.upsert(
                serverResult: ServerResultRecord(
                    loginId: loginId,
                    kind: kind.rawValue,
                    key: key,
                    payloadJSON: try ServerResultPayload.empty.jsonText(),
                    fetchedAt: Int64(Date().timeIntervalSince1970) - kind.expiry + 60
                )
            )
        }

        func request(_ kind: ServerResultKind, _ key: String) async {
            await fetcher.request(kind: kind, key: key)
            await fetcher.settle()
        }
    }

    /// What the server said, on stderr for the run log; a passing live test stays green.
    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("[ServerResultAILive] \(line)\n".utf8))
    }

    @Test(.enabled(if: ServerResultAILiveTests.serverEnvironment != nil))
    func smartRepliesLandReadyAndReplaceAStaleEmptyRow() async throws {
        let live = try await Live.open()
        let key = ServerResultKind.messageKey(live.newest.id)

        await live.request(.smartReply, key)
        let first = try await live.payload(.smartReply, key)
        guard case .ready(.array(let items))? = first else {
            Issue.record("smart replies for remote \(live.newest.remoteId): \(String(describing: first))")
            return
        }
        let replies = items.compactMap(\.stringValue)
        #expect(!replies.isEmpty)

        try await live.leaveStaleEmpty(.smartReply, key)
        await live.request(.smartReply, key)
        guard case .ready(let again)? = try await live.payload(.smartReply, key) else {
            Issue.record("the stale empty smart-reply row was not replaced")
            return
        }
        Self.report("smart replies for remote \(live.newest.remoteId): \(replies) then \(again)")
    }

    @Test(.enabled(if: ServerResultAILiveTests.serverEnvironment != nil))
    func threadSummaryAndEventDataLandReadyAndReplaceStaleEmptyRows() async throws {
        let live = try await Live.open()
        let key = ServerResultKind.messageKey(live.reply.id)

        for kind in [ServerResultKind.threadSummary, .eventData] {
            try await live.leaveStaleEmpty(kind, key)
            await live.request(kind, key)
            let payload = try await live.payload(kind, key)
            guard case .ready(let data)? = payload else {
                Issue.record("\(kind.rawValue) for remote \(live.reply.remoteId): \(String(describing: payload))")
                continue
            }
            switch kind {
            case .threadSummary: #expect(data.stringValue?.isEmpty == false)
            default: #expect(data.objectValue?["summary"]?.stringValue?.isEmpty == false)
            }
            Self.report("\(kind.rawValue) for remote \(live.reply.remoteId) \"\(live.reply.subject ?? "")\": \(data)")
        }
    }
}
