// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One entry of `GET /api/internalAddress`, inside the `JSONEnvelope`.
///
/// The live server's list is empty (`{"status":"success","data":[]}`), so the
/// element shape is unverified and every field is optional — the same stance
/// `TrustedSender` takes for the same reason.
public struct InternalAddress: Decodable, Sendable, Hashable {
    public let id: Int?
    public let address: String?
    /// `individual` or `domain`.
    public let type: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case address
        case type
    }
}
