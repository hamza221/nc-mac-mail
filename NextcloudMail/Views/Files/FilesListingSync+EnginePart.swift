// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailSync

/// On demand only, like `ServerResultFetcher`: nothing to start, and offline is how it stops
/// taking requests. A stopped instance is never told it is online again.
extension FilesListingSync: EnginePart {
    nonisolated func engineStart() async {}
    nonisolated func engineStop() async { await apply(conditions: MirrorConditions(isOffline: true)) }
    nonisolated func engineApply(_ conditions: MirrorConditions) async { await apply(conditions: conditions) }
    nonisolated func engineWake() async {}
}
