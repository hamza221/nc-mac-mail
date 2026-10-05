// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore

/// Typed reads off a raw payload object, for the columns a model does not name.
///
/// Lenient in the same way `NCMailCore`'s decoders are: PHP serialises a boolean column as
/// `true`, `1` or `"1"` depending on where it came from, and a wrong-typed value reads as
/// absent rather than failing a whole account refresh.
extension [String: AnyJSON] {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value): value
        case .double(let value): Int(exactly: value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool {
        switch self[key] {
        case .bool(let value): value
        case .int(let value): value != 0
        case .string(let value): value == "1" || value.lowercased() == "true"
        default: false
        }
    }
}

extension AnyJSON {
    /// Decodes a model out of a value already parsed as `AnyJSON`, for the objects a
    /// payload embeds — the aliases inside each `GET /api/accounts` entry.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
