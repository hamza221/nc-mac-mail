// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// The OCS wrapper every `/ocs/v2.php/` route answers with.
public struct OCSResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    public let meta: Meta
    public let data: Payload

    public struct Meta: Decodable, Sendable, Hashable {
        public let status: String
        public let statuscode: Int
        public let message: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case statuscode
            case message
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ocs
    }

    private enum OCSKeys: String, CodingKey {
        case meta
        case data
    }

    public init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: CodingKeys.self)
        let ocs = try outer.nestedContainer(keyedBy: OCSKeys.self, forKey: .ocs)
        meta = try ocs.decode(Meta.self, forKey: .meta)
        data = try ocs.decode(Payload.self, forKey: .data)
    }
}

/// `GET {server}/ocs/v2.php/cloud/capabilities`, trimmed to what the app reads.
///
/// Only theming matters in v1: the instance's primary colour drives `NCBrand`
/// and has to be applied before the first frame, so it is cached in `meta` and
/// re-read in the background.
public struct Capabilities: Decodable, Sendable, Hashable {
    public let version: Version?
    public let theming: Theming?

    public struct Version: Decodable, Sendable, Hashable {
        public let major: Int?
        public let minor: Int?
        public let micro: Int?
        public let string: String?

        private enum CodingKeys: String, CodingKey {
            case major
            case minor
            case micro
            case string
        }
    }

    public struct Theming: Decodable, Sendable, Hashable {
        public let name: String?
        public let productName: String?
        public let slogan: String?
        public let url: String?
        /// The instance's primary colour as `#rrggbb`. This is the one field
        /// the app cannot start correctly without.
        public let color: String?
        public let colorText: String?
        public let background: String?
        public let logo: String?
        public let favicon: String?
        public let cacheBuster: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case productName
            case slogan
            case url
            case color
            case colorText = "color-text"
            case background
            case logo
            case favicon
            case cacheBuster
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case capabilities
    }

    private enum CapabilityKeys: String, CodingKey {
        case theming
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Version.self, forKey: .version)
        let capabilities = try container.nestedContainer(keyedBy: CapabilityKeys.self, forKey: .capabilities)
        theming = try capabilities.decodeIfPresent(Theming.self, forKey: .theming)
    }
}
