// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// One server-state refresh against a live server, timed, with the rows each kind left.
///
/// Off by default, like every live test: it opens sockets. It answers the brief's "measured
/// cost of a full settings refresh at launch", and it is the smoke run that shows which
/// kinds land rows on a real instance.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter ServerStateLive
/// ```
@Suite("Server state against a live server")
struct ServerStateLiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR"]

    @Test(.enabled(if: ServerStateLiveTests.serverEnvironment != nil))
    func refreshesEveryKind() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_MIRROR"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw MirrorLiveMeasurementTests.LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let counter = RequestCounter()
        let client = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            transport: CountingTransport(counter: counter),
            clientVersion: "measurement"
        )
        let identity = ServerIdentity(serverURL: server, loginName: user)
        let accounts = try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity)
        let account = try #require(accounts.first)
        let loginId = try #require(try await store.ensureLogin(identity).id)
        let mirror = ServerStateMirror(
            store: store,
            client: client,
            identity: identity,
            // The poll is not what is measured; a launch refresh is.
            configuration: ServerStateConfiguration(sleep: { _ in throw CancellationError() })
        )

        let cold = await mirror.refresh(trigger: .launch)
        let warm = await mirror.refresh(trigger: .settingsOpened)

        let fetcher = ServerResultFetcher(store: store, client: client, identity: identity)
        await fetcher.request(kind: .autoComplete, key: "a")
        await fetcher.request(kind: .quota, key: ServerResultKind.accountKey(account.id))
        await fetcher.settle()

        let rows: [(String, Int)] = [
            ("alias", try await store.aliases(accountId: account.id).count),
            (
                "quota",
                try await store.serverResult(kind: "quota", key: String(account.id), loginId: loginId) == nil ? 0 : 1
            ),
            ("delegation", try await store.delegations(accountId: account.id).count),
            ("sieveState", try await store.sieveState(accountId: account.id) == nil ? 0 : 1),
            ("quickAction", try await store.quickActions(accountId: account.id).count),
            (
                "preference(non-null)",
                try await ServerStateConfiguration.webClientPreferenceKeys.asyncCount { key in
                    try await store.preferenceValue(key: key, loginId: loginId) != nil
                }
            ),
            ("textBlock", try await store.textBlocks(loginId: loginId).count),
            ("trustedSender", try await store.trustedSenders(loginId: loginId).count),
            ("internalAddress", try await store.internalAddresses(loginId: loginId).count),
            ("smimeCertificate", try await store.smimeCertificates(loginId: loginId).count),
            ("outboxMessage", try await store.outboxMessages().count),
            ("recipientSuggestion(a)", try await store.recipientSuggestions(term: "a", loginId: loginId).count),
        ]
        Issue.record(
            """
            live server state: cold \(cold.duration) / \(cold.requests) requests, \
            warm \(warm.duration) / \(warm.requests) requests, \(await counter.count) requests in total; \
            refreshed \(cold.refreshed.sorted().map(\.rawValue)), \
            failed \(cold.failed.sorted { $0.key < $1.key }.map { "\($0.key.rawValue): \($0.value)" }); \
            rows \(rows.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
            """
        )
        #expect(cold.failed.isEmpty)
    }
}

extension Sequence where Element: Sendable {
    fileprivate func asyncCount(_ predicate: (Element) async throws -> Bool) async rethrows -> Int {
        var count = 0
        for element in self where try await predicate(element) { count += 1 }
        return count
    }
}
