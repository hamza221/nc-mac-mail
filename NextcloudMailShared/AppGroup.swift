// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The one container the app and its two extensions share (ADR-0100). Compiled into all
/// three targets from `NextcloudMailShared/`, so the identifier and the paths below are
/// spelled once. It holds the widget snapshot (ADR-0071) and the Share extension's inbox;
/// the mirror and its WAL stay in the app's own container.
///
/// The identifier is the team-prefixed macOS form, `$(TeamIdentifierPrefix)com.nextcloud.mail.macos`,
/// not `group.…`: a `group.` identifier needs a provisioning profile, which the project's
/// ad-hoc signing does not have (ADR-0100). Ad-hoc it expands to `com.nextcloud.mail.macos`,
/// signed by a team to `TEAMID.com.nextcloud.mail.macos`; each target's Info.plist carries
/// the expanded value under ``infoKey`` so the code always names the group it is entitled to.
nonisolated enum AppGroup {
    static let infoKey = "NCMailAppGroup"

    /// Must equal every target's `com.apple.security.application-groups` entitlement
    /// (`AppGroupTests`).
    static var identifier: String {
        (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String) ?? "com.nextcloud.mail.macos"
    }

    /// The group container, or nil when this process is not entitled to it.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
