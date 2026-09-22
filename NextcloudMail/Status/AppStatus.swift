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
/// `mirror` and `pendingFailures` are written from outside: `NCMailSync/Mirror/**` (WS-04)
/// and `NCMailSync/Operations/**` (WS-06) cannot import this app-target type themselves —
/// dependencies point downward only
/// ([overview.md](../../docs/architecture/overview.md#modules)) — so the app-side glue that
/// wires each account's coordinator and drainer assigns into these properties on their
/// behalf, always on the main actor. Neither exists yet, so both start at their quiet
/// default and nothing currently changes them.
@MainActor
@Observable
final class AppStatus {
    var mirror: MirrorProgress?
    var isOffline = false
    var pendingFailures = 0

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
