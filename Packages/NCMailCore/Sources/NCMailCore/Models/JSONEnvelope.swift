// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A response type the client may synthesise from a `204 No Content`.
///
/// `GET /api/thread/{id}/summary` and `GET /api/messages/{id}/smartreply`
/// answer 204 with an empty body when the server has no LLM provider (verified
/// live, Mail 5.12). `JSONDecoder` cannot decode zero bytes, so `MailClient`
/// checks for this conformance and builds the "nothing there" value directly.
public protocol EmptyBodyRepresentable {
    init()
}

/// The `{"status": …, "data": …}` wrapper `OCA\Mail\Http\JsonResponse` puts
/// around most settings and mutation payloads.
///
/// `status` is optional because the wrapper is not applied uniformly:
/// `GET /api/accounts/{id}/test` answers `{"data": true}` with no status at all
/// (verified live, Mail 5.12). `data` may be `null` — the eventdata route sends
/// `{"data": null}` when nothing was extracted — so an optional `Payload`
/// decodes that, and a missing `data` key is also nil rather than an error.
public struct JSONEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    public let status: String?
    public let data: Payload

    public init(status: String?, data: Payload) {
        self.status = status
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        if let value = try container.decodeIfPresent(Payload.self, forKey: .data) {
            data = value
        } else if let nilType = Payload.self as? any ExpressibleByNilLiteral.Type,
            let value = nilType.init(nilLiteral: ()) as? Payload
        {
            // nilType is Payload.self, so its nil literal is a Payload.
            data = value
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.data,
                .init(codingPath: decoder.codingPath, debugDescription: "no data and Payload is not optional")
            )
        }
    }
}

extension JSONEnvelope: Equatable where Payload: Equatable {}
extension JSONEnvelope: Hashable where Payload: Hashable {}

/// A 204 decodes to "the server said nothing", which for an optional payload is
/// simply nil — the same meaning an explicit `{"data": null}` carries.
extension JSONEnvelope: EmptyBodyRepresentable where Payload: ExpressibleByNilLiteral {
    public init() {
        self.init(status: nil, data: nil)
    }
}
