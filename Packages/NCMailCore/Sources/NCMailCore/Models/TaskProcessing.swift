// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /ocs/v2.php/taskprocessing/tasktypes`, inside the OCS wrapper — the
/// user-readable source for the `llm_*` and `context_chat_available` flags
/// (`docs/reference/server-flags.md`).
///
/// `types` is an object keyed by task type id (`core:text2text:summary`,
/// `context_chat:context_chat`, …). With no provider PHP serialises the empty
/// map as `[]` (verified live: `{"types":[]}`), hence the PHP-dictionary
/// decode. Only the ids are read; each type's description is kept raw.
public struct TaskTypes: Decodable, Sendable, Hashable {
    public let types: [String: AnyJSON]

    /// The task type ids Mail's flags test for.
    public enum Known {
        public static let summary = "core:text2text:summary"
        public static let freePrompt = "core:text2text"
        public static let translate = "core:text2text:translate"
        public static let contextChat = "context_chat:context_chat"
    }

    public func isAvailable(_ id: String) -> Bool {
        types[id] != nil
    }

    private enum CodingKeys: String, CodingKey {
        case types
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        types = try container.decodePHPDictionary(AnyJSON.self, forKey: .types)
    }
}
