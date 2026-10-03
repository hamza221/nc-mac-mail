// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Network
import OSLog

/// What the current path allows, as three booleans.
///
/// The app's own type rather than `NCMailSync.MirrorConditions` so that `NCMailSync` stays
/// imported in exactly one app file; `AccountEngine` converts. The three fields are the same
/// three, because they are the three `NWPath` answers that change what the sync engine is
/// allowed to do ([ADR-0031](../../docs/decisions/0031-conditions-pushed-power-read.md)).
struct NetworkConditions: Equatable, Sendable {
    var isOffline = false
    var isExpensive = false
    var isConstrained = false
}

/// The one `NWPathMonitor` in the app.
///
/// It lives in the shell rather than in the sync engine so that the backfill, the sync
/// scheduler and the drainer all read one answer instead of each running its own monitor and
/// disagreeing for a moment at the edge of a change ([WS-13's brief](../../docs/delivery/briefs/WS-13-app-shell.md)).
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nextcloud.mail.macos.path-monitor")
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "network")

    /// Calls `onChange` on every transition, on the main actor, since every observer
    /// (`AppStatus`, `AccountEngine`) lives there. `NWPathMonitor` itself calls back on
    /// `queue`.
    func start(onChange: @escaping @MainActor (NetworkConditions) -> Void) {
        monitor.pathUpdateHandler = { path in
            let conditions = NetworkConditions(
                isOffline: path.status != .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor in onChange(conditions) }
        }
        monitor.start(queue: queue)
        Self.logger.debug("path monitor started")
    }

    func stop() {
        monitor.cancel()
    }
}
