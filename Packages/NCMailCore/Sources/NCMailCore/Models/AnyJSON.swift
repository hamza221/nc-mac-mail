// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A decoded JSON value of any shape.
///
/// This exists so `RawBacked` can hold everything the server sent, including the
/// fields no Swift model names. Without it a payload would have to be modelled
/// exhaustively before the store could keep `rawJSON`, and the point of keeping
/// `rawJSON` is precisely the fields nobody thought to model yet.
///
/// Integers stay integers. A message id round-tripped through `Double` is a
/// rounding bug waiting for the first account with more than 2^53 rows, and,
/// more immediately, it changes how the value prints.
public enum AnyJSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "value is not JSON"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The value as a string, for the preference endpoint, which answers with
    /// whatever type the user's stored setting happens to have.
    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        case .null, .array, .object: nil
        }
    }

    /// The members of an object, or `nil` for every other shape.
    public var objectValue: [String: AnyJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
