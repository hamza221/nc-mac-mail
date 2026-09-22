// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Recorded server responses, as bytes, and nothing else.
///
/// This target depends on nothing — not `NCMailCore`, not `NCMailNet`, not `NCMailStore`.
/// That is the whole point of it. `NCMailTestSupport` (the package this target lives in)
/// depends on all three, so if the bytes lived in the `NCMailTestSupport` target itself,
/// `NCMailCoreTests` importing them would need `NCMailCore` to depend back on
/// `NCMailTestSupport`, which is the package cycle ADR-0022 hit and ADR-0026 replaces. A
/// target with no dependencies has nothing to cycle back to, so `NCMailCoreTests`,
/// `NCMailStoreTests` and anything else that only needs the raw fixture can depend on this
/// one directly.
///
/// Model-aware helpers — decoding into a specific `NCMailCore` type with its exact decoder
/// configuration, or a `FakeTransport` that speaks `NCMailNet`'s `MailTransport` — stay in
/// the `NCMailTestSupport` target, which can afford the three dependencies because nothing
/// downstream of it needs to import it back.
public enum FixtureBytes {
    public enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let name): "no fixture named \(name)"
            }
        }
    }

    /// A recorded fixture's exact bytes, by the file name `Scripts/record-fixtures.sh` wrote.
    public static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else { throw FixtureError.notFound(name) }
        return try Data(contentsOf: url)
    }

    /// Every recorded fixture's file name, for a test that wants to sweep all of them —
    /// asserting none leaks real data, for instance, rather than trusting a human to grep.
    public static func allNames() throws -> [String] {
        guard let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        else { throw FixtureError.notFound("Fixtures directory") }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// Decodes a fixture with a plain `JSONDecoder`. A decoder tuned to a particular model —
    /// date strategies, key strategies — belongs to the caller; this target has no models to
    /// tune one for.
    public static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
