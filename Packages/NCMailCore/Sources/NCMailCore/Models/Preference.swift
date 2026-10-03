// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/preferences/{key}`.
///
/// The response is `{"value": …}`, not the bare value, and `value` is null when
/// the user never set that preference. `sort-order` is the one that matters:
/// unset means the server's default, newest first, and a user who chose oldest
/// first in the web client changes what a `cursor` means.
public struct Preference: Decodable, Sendable, Hashable {
    public let value: AnyJSON

    public var stringValue: String? { value.stringValue }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(AnyJSON.self, forKey: .value) ?? .null
    }
}

/// The sort order the user picked in the web client. It is a server-side
/// preference and not a query parameter, so the client reads it once at launch
/// and passes the matching `sortOrder` to every sync.
public enum SortOrder: String, Sendable, CaseIterable {
    case newest
    case oldest

    /// The server's default when the preference was never written.
    public static let `default` = SortOrder.newest

    public init(preference: Preference) {
        self = SortOrder(rawValue: preference.stringValue ?? "") ?? .default
    }
}

/// `GET /api/trustedsenders`, which answers with the `JsonResponse::success`
/// envelope rather than a bare array.
public struct TrustedSendersResponse: Decodable, Sendable {
    public let status: String?
    public let data: [TrustedSender]

    private enum CodingKeys: String, CodingKey {
        case status
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        data = try container.decodeArray(TrustedSender.self, forKey: .data)
    }
}

/// One entry of the trusted-sender list. Every field is optional: the test
/// server's list is empty, so no recorded fixture pins the element shape down.
public struct TrustedSender: Decodable, Sendable, Hashable {
    public let id: Int?
    public let email: String?
    /// `individual` or `domain`.
    public let type: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case type
    }
}
