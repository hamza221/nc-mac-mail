// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/messages/{id}/source` — the raw RFC 822 message, as JSON.
///
/// Verified live (Mail 5.12): `{"source":"Delivered-To: …"}`. The `.eml`
/// download is the separate `/export` route, which answers bytes, not JSON.
public struct MessageSource: Decodable, Sendable, Hashable {
    public let source: String

    private enum CodingKeys: String, CodingKey {
        case source
    }
}

/// `GET /api/messages/{id}/dkim`.
///
/// Verified live (Mail 5.12): `{"valid":false}` — bare, no envelope.
public struct DkimResult: Decodable, Sendable, Hashable {
    public let valid: Bool

    private enum CodingKeys: String, CodingKey {
        case valid
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        valid = try container.decodeLenientBool(forKey: .valid)
    }
}
