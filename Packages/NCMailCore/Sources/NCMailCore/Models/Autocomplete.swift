// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One suggestion from `GET /api/autoComplete?term=` — a bare array, no envelope.
///
/// Verified live (Mail 5.12). A contact entry:
/// `{"id":"admin","label":"admin","email":"admin@example.net","photo":null,"source":"contacts"}`;
/// a group entry carries the group id in `email` (`"nextcloud:admin"`) and no
/// `photo` key at all; a collected address carries its integer row id in `id`.
/// `source` is `contacts`, `collected`, `users` or `groups`.
public struct AutocompleteRecipient: Decodable, Sendable, Hashable {
    public let id: String?
    public let label: String?
    public let email: String?
    public let photo: String?
    public let source: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
        case photo
        case source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeStringOrInteger(forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        photo = try container.decodeIfPresent(String.self, forKey: .photo)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

/// One contact from `GET /api/contactIntegration/autoComplete/{term}` and
/// `GET /api/contactIntegration/match/{mail}` — a bare array.
///
/// Verified live: `{"id":"admin","label":"admin","email":["admin@example.net"]}`.
/// Unlike ``AutocompleteRecipient``, `email` is an **array** here: the Contacts
/// integration returns every address of the matched card.
public struct ContactMatch: Decodable, Sendable, Hashable {
    public let id: String?
    public let label: String?
    public let email: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeStringOrInteger(forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // Defensive: the web client treats a lone string as one address too.
        if let list = try? container.decode([String].self, forKey: .email) {
            email = list
        } else if let single = try? container.decode(String.self, forKey: .email) {
            email = [single]
        } else {
            email = []
        }
    }
}
