// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Network
import OSLog

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
    /// (`AppStatus`) lives there. `NWPathMonitor` itself calls back on `queue`.
    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let isOffline = path.status != .satisfied
            Task { @MainActor in onChange(isOffline) }
        }
        monitor.start(queue: queue)
        Self.logger.debug("path monitor started")
    }

    func stop() {
        monitor.cancel()
    }
}
