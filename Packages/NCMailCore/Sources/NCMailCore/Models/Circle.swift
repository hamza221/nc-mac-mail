// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One team (née circle) from `GET /ocs/v2.php/apps/circles/circles`, inside
/// the OCS wrapper.
///
/// Verified live (Nextcloud 36) by creating one: the id is an opaque string
/// (`"QxdjexbNSN2…"`), and the payload carries a large member/config graph the
/// client does not read. Only what a recipient-picker row needs is modelled;
/// autocomplete usually arrives through `/api/autoComplete` instead, which
/// reports circles as `source: "circles"`.
public struct Circle: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let displayName: String?
    public let population: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName
        case population
    }
}
