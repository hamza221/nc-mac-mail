// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One certificate from `GET /api/smime/certificates`, inside the
/// `JSONEnvelope`; `POST /api/smime/certificates` (multipart) echoes one back.
///
/// Shape pinned by `smime-certificates.json`, recorded after uploading a
/// self-signed certificate: the parsed metadata lives in a nested `info`
/// object, not at the top level.
///
/// ```json
/// { "id": 1, "emailAddress": "…", "hasKey": true,
///   "info": { "commonName": "…", "emailAddress": "…", "notAfter": 1791232283,
///             "purposes": { "sign": true, "encrypt": true },
///             "isChainVerified": false } }
/// ```
public struct SmimeCertificate: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let emailAddress: String?
    public let hasKey: Bool
    public let info: Info?

    /// The parsed X.509 metadata the settings list renders.
    public struct Info: Decodable, Sendable, Hashable {
        public let commonName: String?
        public let emailAddress: String?
        /// Unix seconds; `notAfter` in the X.509 sense.
        public let notAfter: Int?
        public let purposes: Purposes?
        public let isChainVerified: Bool

        private enum CodingKeys: String, CodingKey {
            case commonName
            case emailAddress
            case notAfter
            case purposes
            case isChainVerified
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commonName = try container.decodeIfPresent(String.self, forKey: .commonName)
            emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
            notAfter = try container.decodeIfPresent(Int.self, forKey: .notAfter)
            purposes = try container.decodeIfPresent(Purposes.self, forKey: .purposes)
            isChainVerified = try container.decodeLenientBool(forKey: .isChainVerified)
        }
    }

    /// What the certificate may be used for, as OpenSSL reports it.
    public struct Purposes: Decodable, Sendable, Hashable {
        public let sign: Bool
        public let encrypt: Bool

        private enum CodingKeys: String, CodingKey {
            case sign
            case encrypt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sign = try container.decodeLenientBool(forKey: .sign)
            encrypt = try container.decodeLenientBool(forKey: .encrypt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case emailAddress
        case hasKey
        case info
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
        hasKey = try container.decodeLenientBool(forKey: .hasKey)
        info = try container.decodeIfPresent(Info.self, forKey: .info)
    }
}
