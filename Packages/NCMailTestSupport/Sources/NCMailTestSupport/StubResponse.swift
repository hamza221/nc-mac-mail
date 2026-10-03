// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
import NCMailFixtures

/// What `FakeTransport` hands back for a matched request.
public struct StubResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int = 200, body: Data = Data("{}".utf8), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public static func json(_ text: String, status: Int = 200) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8))
    }

    /// A recorded fixture, replayed verbatim. The usual way a decoding test wires itself up:
    /// `.fixture("accounts.json")` is the exact bytes `Scripts/record-fixtures.sh` wrote.
    public static func fixture(_ name: String, status: Int = 200) throws -> StubResponse {
        StubResponse(status: status, body: try FixtureBytes.data(name))
    }

    /// A bare status with an empty body — a 204, a 404 with nothing to say.
    public static func status(_ code: Int) -> StubResponse {
        StubResponse(status: code, body: Data())
    }

    /// A 429 or 503 carrying the header `RetryPolicy` is required to honour exactly.
    public static func retryAfter(_ seconds: Int, status: Int = 429) -> StubResponse {
        StubResponse(status: status, headers: ["Retry-After": String(seconds)])
    }
}
