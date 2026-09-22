// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// A decoded model together with the JSON it came from.
///
/// `schema.sql` gives `account`, `mailbox` and `message` a `rawJSON` column so a
/// field the client does not model yet survives a sync and can be read later
/// without a refetch. Wrapping is the alternative to putting `rawData: Data` in
/// every model: the models stay plain value types that a test can build by hand,
/// and only the calls whose result the store persists pay for the extra copy.
/// ADR-0020.
///
/// `rawJSON()` re-encodes rather than slicing the response, because `Decodable`
/// never sees the byte range an element occupied. The re-encoded form carries
/// the same values with sorted keys, which is what the store needs and also
/// makes two recordings of one payload compare equal.
public struct RawBacked<Value: Decodable & Sendable>: Decodable, Sendable {
    public let value: Value
    /// Everything the server sent for this object, including unmodelled fields.
    public let json: AnyJSON

    public init(value: Value, json: AnyJSON) {
        self.value = value
        self.json = json
    }

    public init(from decoder: any Decoder) throws {
        value = try Value(from: decoder)
        json = try AnyJSON(from: decoder)
    }

    /// The JSON to persist in a `rawJSON` column.
    public func rawJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }
}

extension RawBacked: Equatable where Value: Equatable {}
extension RawBacked: Hashable where Value: Hashable {}
