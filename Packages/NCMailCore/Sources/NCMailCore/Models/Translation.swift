// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /ocs/v2.php/translation/languages`, inside the OCS wrapper.
///
/// Verified live (Nextcloud 36): `{"languages":[],"languageDetection":false}` —
/// the route exists even with no translation provider installed, which is
/// itself the availability signal the translation UI needs. The element shape
/// follows the OCS translation API (`from`/`fromLabel`/`to`/`toLabel`) and is
/// unverified live, so every field is optional.
public struct TranslationLanguages: Decodable, Sendable, Hashable {
    public let languages: [LanguagePair]
    public let languageDetection: Bool

    public struct LanguagePair: Decodable, Sendable, Hashable {
        public let from: String?
        public let fromLabel: String?
        public let to: String?
        public let toLabel: String?

        private enum CodingKeys: String, CodingKey {
            case from
            case fromLabel
            case to
            case toLabel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case languages
        case languageDetection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languages = try container.decodeArray(LanguagePair.self, forKey: .languages)
        languageDetection = try container.decodeLenientBool(forKey: .languageDetection)
    }
}

/// `POST /ocs/v2.php/translation/translate`, inside the OCS wrapper.
///
/// With no provider the server answers OCS 412 with
/// `data.message = "No translation provider available"` (verified live), which
/// surfaces as `MailError`. The success shape (`text`, detected `from`) follows
/// the OCS translation API and is unverified live, so both are optional.
public struct TranslationResult: Decodable, Sendable, Hashable {
    public let text: String?
    public let from: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case from
    }
}
