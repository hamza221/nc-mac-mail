// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// Wiring for the server-state mirror and the result fetcher: a route per mirrored kind,
/// answered from the recordings, and a snapshot of every table the mirror writes so a test
/// can say "nothing changed" in one comparison.
enum ServerStateTest {
    static let api = MirrorTest.apiRoot

    static func route(_ path: String) -> RequestMatcher { .path("\(api)/\(path)") }

    /// The server account id every recording here is about (`accounts.json`'s first entry).
    static let remoteAccountId = 1

    /// The route, or routes, each kind reads. A failure test fails the first of them.
    static func routes(of kind: ServerStateKind) -> [RequestMatcher] {
        switch kind {
        case .accounts: [MirrorTest.accountsRoute]
        case .quota: [route("accounts/\(remoteAccountId)/quota")]
        case .delegations: [route("delegations/\(remoteAccountId)")]
        case .sieve:
            [
                route("sieve/active/\(remoteAccountId)"), route("filter/\(remoteAccountId)"),
                route("out-of-office/\(remoteAccountId)"),
            ]
        case .quickActions: [route("quick-actions")]
        case .preferences: [.pathContains("\(api)/preferences/")]
        case .textBlocks: [route("textBlocks"), route("textBlockshares"), .pathSuffix("/shares")]
        case .trustedSenders: [route("trustedsenders")]
        case .internalAddresses: [route("internalAddress")]
        case .smimeCertificates: [route("smime/certificates")]
        case .outbox: [route("outbox")]
        }
    }

    /// Every kind answered from a recording that has something in it.
    ///
    /// - Parameter sieveEnabled: answer the accounts route with the recording taken while
    ///   the account had Sieve on, and the three Sieve routes with what they said then.
    static func stubEverything(_ transport: FakeTransport, sieveEnabled: Bool = false) async throws {
        await transport.stub(
            MirrorTest.accountsRoute,
            with: try .fixture(sieveEnabled ? "accounts-sieve-enabled.json" : "accounts-signatures.json")
        )
        await transport.stub(route("accounts/\(remoteAccountId)/quota"), with: try .fixture("account-quota.json"))
        await transport.stub(route("delegations/\(remoteAccountId)"), with: try .fixture("delegations.json"))
        if sieveEnabled {
            await transport.stub(
                route("sieve/active/\(remoteAccountId)"), with: try .fixture("sieve-active-enabled.json"))
            await transport.stub(route("filter/\(remoteAccountId)"), with: try .fixture("filters-enabled.json"))
            await transport.stub(
                route("out-of-office/\(remoteAccountId)"), with: try .fixture("out-of-office-enabled.json"))
        }
        await transport.stub(route("quick-actions"), with: try .fixture("quick-actions.json"))
        await transport.stub(.pathContains("\(api)/preferences/"), with: try .fixture("preference-sort-order.json"))
        await transport.stub(route("textBlocks"), with: try .fixture("text-blocks.json"))
        await transport.stub(route("textBlockshares"), with: try .fixture("text-block-shares-all.json"))
        await transport.stub(.pathSuffix("/shares"), with: try .fixture("text-block-shares.json"))
        await transport.stub(route("trustedsenders"), with: try .fixture("trustedsenders-populated.json"))
        await transport.stub(route("internalAddress"), with: try .fixture("internal-addresses-populated.json"))
        await transport.stub(route("smime/certificates"), with: try .fixture("smime-certificates.json"))
        await transport.stub(route("outbox"), with: try .fixture("outbox.json"))
    }

    /// A sleeper that ends the outbox poll at once, so a test that is not about the poll
    /// does not leave one running.
    static func configuration(
        clock: TestClock = TestClock(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() }
    ) -> ServerStateConfiguration {
        ServerStateConfiguration(now: { clock.now }, sleep: sleep)
    }

    struct Setup {
        let store: MailStore
        let accountId: Int64
        let loginId: Int64
    }

    static func store() async throws -> Setup {
        let store = try MailStore.inMemory()
        let accountId = try await MirrorTest.mirroredAccount(store)
        let loginId = try #require(try await store.ensureLogin(MirrorTest.identity).id)
        return Setup(store: store, accountId: accountId, loginId: loginId)
    }

    /// `MirrorTest.client` for a transport that is not the fake itself.
    static func client(_ transport: any MailTransport) throws -> MailClient {
        guard let url = URL(string: MirrorTest.server) else { throw MirrorTest.SetupError.badServerURL }
        return MailClient(
            server: url,
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: transport,
            retryPolicy: .none,
            clientVersion: "test"
        )
    }

    static func mirror(
        _ setup: Setup,
        transport: FakeTransport,
        configuration: ServerStateConfiguration = configuration(),
        onFollowedUp: @escaping @Sendable ([Int64]) async -> Void = { _ in }
    ) throws -> ServerStateMirror {
        ServerStateMirror(
            store: setup.store,
            client: try MirrorTest.client(transport),
            identity: MirrorTest.identity,
            configuration: configuration,
            onFollowedUp: onFollowedUp
        )
    }

    /// Every row the mirror writes, per kind.
    struct Snapshot: Equatable {
        var signature: String?
        var aliases: [AliasRecord]
        var quota: ServerResultRecord?
        var delegations: [DelegationRecord]
        var sieve: SieveStateRecord?
        var quickActions: [QuickActionRecord]
        var quickActionSteps: [QuickActionStepRecord]
        var preferences: [String: String?]
        var textBlocks: [TextBlockRecord]
        var textBlockShares: [TextBlockShareRecord]
        var trustedSenders: [TrustedSenderRecord]
        var internalAddresses: [InternalAddressRecord]
        var smimeCertificates: [SmimeCertificateRecord]
        var outbox: [OutboxMessageRecord]

        /// Whether `kind`'s rows are the same in both.
        func same(_ kind: ServerStateKind, as other: Snapshot) -> Bool {
            switch kind {
            case .accounts: signature == other.signature && aliases == other.aliases
            case .quota: quota == other.quota
            case .delegations: delegations == other.delegations
            case .sieve: sieve == other.sieve
            case .quickActions: quickActions == other.quickActions && quickActionSteps == other.quickActionSteps
            case .preferences: preferences == other.preferences
            case .textBlocks: textBlocks == other.textBlocks && textBlockShares == other.textBlockShares
            case .trustedSenders: trustedSenders == other.trustedSenders
            case .internalAddresses: internalAddresses == other.internalAddresses
            case .smimeCertificates: smimeCertificates == other.smimeCertificates
            case .outbox: outbox == other.outbox
            }
        }
    }

    static func snapshot(_ setup: Setup) async throws -> Snapshot {
        let store = setup.store
        let actions = try await store.quickActions(accountId: setup.accountId)
        var steps: [QuickActionStepRecord] = []
        for action in actions {
            steps += try await store.quickActionSteps(quickActionId: try #require(action.id))
        }
        let blocks = try await store.textBlocks(loginId: setup.loginId)
        var shares: [TextBlockShareRecord] = []
        for block in blocks {
            shares += try await store.textBlockShares(textBlockId: try #require(block.id))
        }
        var preferences: [String: String?] = [:]
        for key in ServerStateConfiguration.webClientPreferenceKeys {
            preferences[key] = try await store.preferenceValue(key: key, loginId: setup.loginId)
        }
        return Snapshot(
            signature: try await store.account(id: setup.accountId)?.signature,
            aliases: try await store.aliases(accountId: setup.accountId),
            quota: try await store.serverResult(
                kind: ServerResultKind.quota.rawValue,
                key: ServerResultKind.accountKey(setup.accountId),
                loginId: setup.loginId
            ),
            delegations: try await store.delegations(accountId: setup.accountId),
            sieve: try await store.sieveState(accountId: setup.accountId),
            quickActions: actions,
            quickActionSteps: steps,
            preferences: preferences,
            textBlocks: blocks,
            textBlockShares: shares,
            trustedSenders: try await store.trustedSenders(loginId: setup.loginId),
            internalAddresses: try await store.internalAddresses(loginId: setup.loginId),
            smimeCertificates: try await store.smimeCertificates(loginId: setup.loginId),
            outbox: try await store.outboxMessages()
        )
    }

    /// A raw recording, for assertions against what the server really sent.
    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: try FixtureBytes.data(name))
    }
}

/// Records every duration a sleeper was asked for and returns at once.
final class RecordingSleeper: Sendable {
    private let calls = Mutex<[Duration]>([])

    var durations: [Duration] { calls.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        calls.withLock { $0.append(duration) }
    }
}

/// A transport that holds every request matching `matcher` until the test opens the gate,
/// then hands it to `inner`. Unlike `FakeTransport.stall`, the hold cannot miss a request
/// that arrives before the test registers interest: the gate exists from the start, and
/// ``waitForHeld(_:)`` says when the request has reached it.
actor GatedTransport: MailTransport {
    private let inner: FakeTransport
    private let matcher: RequestMatcher
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldCount = 0

    init(inner: FakeTransport, holding matcher: RequestMatcher) {
        self.inner = inner
        self.matcher = matcher
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if !isOpen, matcher.matches(request) {
            heldCount += 1
            await withCheckedContinuation { held.append($0) }
        }
        return try await inner.send(request)
    }

    /// Returns once `count` requests have reached the gate.
    func waitForHeld(_ count: Int = 1) async {
        while heldCount < count { await Task.yield() }
    }

    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held.removeAll()
    }
}
