// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One notification from `GET /ocs/v2.php/apps/notifications/api/v2/notifications`,
/// inside the OCS wrapper.
///
/// Unverified live: the notifications app is not installed on the dev server,
/// and the route answers OCS 404 (`statuscode` 998 in the meta). The field list
/// follows the notifications app's published OCS API; everything but the id is
/// optional, and the client must treat the whole route as optional — a server
/// without the app is a normal server.
public struct ServerNotification: Decodable, Sendable, Hashable {
    public let notificationId: Int
    public let app: String?
    public let user: String?
    /// ISO 8601.
    public let datetime: String?
    public let objectType: String?
    public let objectId: String?
    public let subject: String?
    public let message: String?
    public let link: String?
    public let icon: String?

    private enum CodingKeys: String, CodingKey {
        case notificationId = "notification_id"
        case app
        case user
        case datetime
        case objectType = "object_type"
        case objectId = "object_id"
        case subject
        case message
        case link
        case icon
    }
}
