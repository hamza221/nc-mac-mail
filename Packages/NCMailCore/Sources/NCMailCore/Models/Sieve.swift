// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/sieve/active/{id}` — a **bare** object, no `JSONEnvelope`
/// (verified live with ManageSieve enabled, Mail 5.x):
/// `{"scriptName":null,"script":""}` when no script is active. With
/// ManageSieve disabled the route is a 400 fail envelope instead, which
/// `MailClient` surfaces as `MailError` before decoding.
public struct SieveScript: Decodable, Sendable, Hashable {
    public let scriptName: String?
    public let script: String?

    private enum CodingKeys: String, CodingKey {
        case scriptName
        case script
    }
}

/// One mail filter from `GET /api/filter/{accountId}`, which answers a **bare**
/// JSON array (verified live with ManageSieve enabled: `[]` on an account
/// without filters). With ManageSieve disabled the route answers **HTTP 500
/// with an empty body** (observed, Mail 5.12). The field list follows
/// `plan/API.md`'s PUT contract, which is also what GET returns, parsed back
/// out of the managed Sieve section.
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

/// The `state` of ``OutOfOfficeFetch``. Fields follow the POST contract:
/// `enabled`, nullable ISO dates, `subject`, `message`. Not yet seen non-null
/// live (the recording account has no out-of-office set).
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

/// `GET /api/out-of-office/{accountId}`, inside the `JSONEnvelope` (verified
/// live with ManageSieve enabled):
/// `{"status":"success","data":{"state":null,"script":"","untouchedScript":""}}`.
/// With ManageSieve disabled the route is the same 400 as the Sieve script.
public struct OutOfOfficeFetch: Decodable, Sendable, Hashable {
    /// Null until an out-of-office has been configured.
    public let state: OutOfOfficeState?
    public let script: String
    public let untouchedScript: String

    private enum CodingKeys: String, CodingKey {
        case state
        case script
        case untouchedScript
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(OutOfOfficeState.self, forKey: .state)
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
        untouchedScript = try container.decodeIfPresent(String.self, forKey: .untouchedScript) ?? ""
    }
}
