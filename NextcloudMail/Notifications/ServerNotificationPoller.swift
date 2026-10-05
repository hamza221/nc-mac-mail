// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog

/// One Nextcloud notification of the Mail app, as the poller stores it and the notifier
/// reads it back. Only what a banner needs: the rendered subject and message the
/// notifications app already localised for the user, and the link it points at.
nonisolated struct MailServerNotice: Codable, Sendable, Equatable {
    var id: Int
    var subject: String
    var message: String?
    var link: String?

    init(id: Int, subject: String, message: String?, link: String?) {
        self.id = id
        self.subject = subject
        self.message = message
        self.link = link
    }

    /// Nil for another app's notification, and for one with nothing to say.
    init?(_ notification: ServerNotification) {
        guard notification.app == "mail", let subject = notification.subject, !subject.isEmpty else { return nil }
        self.init(
            id: notification.notificationId,
            subject: subject,
            message: notification.message.flatMap { $0.isEmpty ? nil : $0 },
            link: notification.link.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// Polls `GET /ocs/v2.php/apps/notifications/api/v2/notifications` every five minutes for one
/// login and writes the Mail app's rows into `serverResult`
/// ([ADR-0067](../../docs/decisions/0067-server-results-are-rows.md)). ``MailNotifier``
/// observes that row; nothing here shows anything.
///
/// Quiet on every failure: no row is written, so the last good list stands and no banner
/// appears. A 404 is a server without the notifications app — a normal server — and stops
/// the polling until the Mac wakes or the app relaunches, rather than asking every five
/// minutes for something that is not there.
///
/// Nothing is deleted on the server after a banner is shown: the web client's notifications
/// menu only dismisses on an explicit click, so a banner here must not make the bell in the
/// browser go quiet.
actor ServerNotificationPoller {
    nonisolated static let kind = "nextcloudNotifications"
    nonisolated static let key = "mail"
    nonisolated static let interval: Duration = .seconds(300)

    private let store: MailStore
    private let client: MailClient
    private let identity: ServerIdentity
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Duration) async throws -> Void
    private var conditions = MirrorConditions()
    private var loginId: Int64?
    private var appMissing = false
    private var loop: Task<Void, Never>?

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "notifications")

    init(
        store: MailStore,
        client: MailClient,
        identity: ServerIdentity,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.client = client
        self.identity = identity
        self.now = now
        self.sleep = sleep
    }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await self.poll()
                do { try await self.sleep(Self.interval) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func apply(conditions newConditions: MirrorConditions) {
        conditions = newConditions
    }

    /// The Mac woke: ask now, and again even if the server had no notifications app.
    func wake() async {
        appMissing = false
        await poll()
    }

    /// One request. Internal so a test drives it without the five-minute sleep.
    func poll() async {
        guard !conditions.isOffline, !appMissing else { return }
        do {
            let response = try await client.get(.notifications)
            let notices = response.data.compactMap(MailServerNotice.init).sorted { $0.id < $1.id }
            try await write(notices)
        } catch MailError.notFound {
            appMissing = true
            Self.logger.info("server has no notifications app; polling paused")
        } catch is CancellationError {
            return
        } catch {
            Self.logger.info("notifications poll failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Unchanged lists are not rewritten, so the notifier's observation is not woken every
    /// five minutes for nothing.
    private func write(_ notices: [MailServerNotice]) async throws {
        let loginId = try await resolveLoginId()
        let payload = String(decoding: try JSONEncoder().encode(notices), as: UTF8.self)
        let existing = try await store.serverResult(kind: Self.kind, key: Self.key, loginId: loginId)
        guard existing?.payloadJSON != payload else { return }
        try await store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: Self.kind, key: Self.key, payloadJSON: payload, fetchedAt: now()))
    }

    private func resolveLoginId() async throws -> Int64 {
        if let loginId { return loginId }
        guard let id = try await store.ensureLogin(identity).id else { throw MailError.notFound }
        loginId = id
        return id
    }
}

/// Started and stopped with its login by ``AccountEngine``, like the other per-login actors.
extension ServerNotificationPoller: EnginePart {
    nonisolated func engineStart() async { await start() }
    nonisolated func engineStop() async { await stop() }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async { await wake() }
}
