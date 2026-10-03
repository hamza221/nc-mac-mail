// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/sieve/active/{id}`, inside the `JSONEnvelope`.
///
/// Unverified live: the test server has ManageSieve disabled and answers
/// `400 {"status":"fail","data":{"message":"ManageSieve is disabled"}}`.
/// The shape comes from `SieveController::getActiveScript`, which returns
/// `scriptName` and `script`; both stay optional until a recording pins them.
public struct SieveScript: Decodable, Sendable, Hashable {
    public let scriptName: String?
    public let script: String?

    private enum CodingKeys: String, CodingKey {
        case scriptName
        case script
    }
}

/// One mail filter from `GET /api/filter/{accountId}`, inside the `JSONEnvelope`.
///
/// Unverified live: with ManageSieve disabled the route answers **HTTP 500 with
/// an empty body** (observed, Mail 5.12 — not the documented error envelope; see
/// the WS-16 report). The field list follows `plan/API.md`'s PUT contract, which
/// is also what GET returns, parsed back out of the managed Sieve section.
public struct MailFilter: Decodable, Sendable, Hashable {
    public let id: Int?
    public let name: String?
    public let enable: Bool
    /// `allof` or `anyof`.
    public let `operator`: String?
    public let priority: Int?
    public let tests: [FilterTest]
    /// Each action is `{type: …}` plus type-specific keys (`addflag`,
    /// `addsystemflag`, `fileinto`, `redirect`, `stop`). Kept raw: the set of
    /// keys per type is unverified, and WS-22's commands round-trip them whole.
    public let actions: [AnyJSON]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enable
        case `operator`
        case priority
        case tests
        case actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        enable = try container.decodeLenientBool(forKey: .enable)
        `operator` = try container.decodeIfPresent(String.self, forKey: .operator)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        tests = try container.decodeArray(FilterTest.self, forKey: .tests)
        actions = try container.decodeArray(AnyJSON.self, forKey: .actions)
    }
}

/// One test of a ``MailFilter``: `{field, operator, values}` where field is
/// `from`, `subject` or `to` and operator is `contains`, `is` or `matches`.
public struct FilterTest: Decodable, Sendable, Hashable {
    public let field: String?
    public let `operator`: String?
    public let values: [String]

    private enum CodingKeys: String, CodingKey {
        case field
        case `operator`
        case values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decodeIfPresent(String.self, forKey: .field)
        `operator` = try container.decodeIfPresent(String.self, forKey: .operator)
        values = try container.decodeArray(String.self, forKey: .values)
    }
}

/// `GET /api/out-of-office/{accountId}`, inside the `JSONEnvelope`.
///
/// Unverified live for the same reason as ``SieveScript`` (ManageSieve
/// disabled → the same 400). Fields follow the POST contract: `enabled`,
/// nullable ISO dates, `subject`, `message`.
public struct OutOfOfficeState: Decodable, Sendable, Hashable {
    public let enabled: Bool
    public let start: String?
    public let end: String?
    public let subject: String?
    public let message: String?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case start
        case end
        case subject
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeLenientBool(forKey: .enabled)
        start = try container.decodeIfPresent(String.self, forKey: .start)
        end = try container.decodeIfPresent(String.self, forKey: .end)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}
