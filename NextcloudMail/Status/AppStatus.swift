// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import SwiftUI

/// One place for everything the sidebar footer might say.
///
/// [ux-spec.md](../../docs/product/ux-spec.md#sidebar) gives the footer a priority order —
/// backfill progress outranks being offline, which outranks a queue with failures in it —
/// and says idle chrome is noise, so ``display`` is exactly one thing or nothing, never a
/// stack of banners.
///
/// `mirror`, `pendingFailures` and `refreshesInFlight` are written from outside, by
/// `AccountEngine`, always on the main actor. `NCMailSync` cannot import this app-target type
/// itself — dependencies point downward only
/// ([overview.md](../../docs/architecture/overview.md#modules)) — so the engine assigns
/// each account's coordinator progress and drainer failures here on their behalf.
@MainActor
@Observable
final class AppStatus {
    var mirror: MirrorProgress?
    var isOffline = false
    var pendingFailures = 0
    /// Explicit refreshes whose sync passes have not all returned. Written by
    /// `AccountEngine.refresh`; the Refresh button spins while it is above zero.
    var refreshesInFlight = 0

    var isRefreshing: Bool { refreshesInFlight > 0 }

    /// What the footer draws. Never more than one case at a time.
    enum Display: Equatable {
        case mirroring(MirrorProgress)
        case offline
        case pendingFailures(Int)
        case none
    }

    var display: Display {
        if let mirror, !mirror.isComplete {
            return .mirroring(mirror)
        }
        if isOffline {
            return .offline
        }
        if pendingFailures > 0 {
            return .pendingFailures(pendingFailures)
        }
        return .none
    }
}
