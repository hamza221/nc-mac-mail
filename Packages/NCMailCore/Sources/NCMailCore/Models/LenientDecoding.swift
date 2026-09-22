// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// Decoding helpers for the places where the Mail app's JSON is loose about
/// types. Each one exists because a real response has both shapes, and the
/// comment on each says which response.
extension KeyedDecodingContainer {
    /// A boolean that may arrive as `0`/`1`.
    ///
    /// `mentionsMe` on an envelope is an integer against Mail 5.12.0-rc.1: the
    /// column is written by a `COUNT(*)` and never cast.
    func decodeLenientBool(forKey key: Key, default fallback: Bool = false) throws -> Bool {
        guard contains(key), try !decodeNil(forKey: key) else { return fallback }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        throw DecodingError.typeMismatch(
            Bool.self,
            .init(codingPath: codingPath + [key], debugDescription: "not a boolean, an integer or a string")
        )
    }

    /// A string that may arrive as the integer `0`.
    ///
    /// `specialRole` is `specialUse[0] ?? 0` in `lib/Db/Mailbox.php`, so a
    /// mailbox with no special use reports the integer rather than null.
    func decodeLenientString(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        // The integer form means "no value", not "the value 0".
        if (try? decode(Int.self, forKey: key)) != nil { return nil }
        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: codingPath + [key], debugDescription: "not a string and not the integer placeholder")
        )
    }

    /// A dictionary that may arrive as `[]`.
    ///
    /// PHP serialises an empty associative array as a JSON array, so an
    /// envelope with no tags has `"tags": []` and one with tags has an object.
    /// Seven of the 95 envelopes in `messages-inbox-page1.json` take the array
    /// form.
    func decodePHPDictionary<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [String: T] {
        guard contains(key), try !decodeNil(forKey: key) else { return [:] }
        if let value = try? decode([String: T].self, forKey: key) { return value }
        if let empty = try? decode([T].self, forKey: key), empty.isEmpty { return [:] }
        throw DecodingError.typeMismatch(
            [String: T].self,
            .init(codingPath: codingPath + [key], debugDescription: "not a dictionary and not an empty array")
        )
    }

    /// A value that is absent on some responses and null on others.
    func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try decodeIfPresent(T.self, forKey: key)
    }

    /// An array that may be null.
    ///
    /// `references` is null or an array, and on Mail 5.12.0-rc.1 always an
    /// array, but the Vue client still guards it.
    func decodeArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        try decodeIfPresent([T].self, forKey: key) ?? []
    }
}
