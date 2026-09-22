// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures

/// Reads the recorded fixtures through `NCMailFixtures`.
///
/// `NCMailFixtures` is a dependency-free product of the `NCMailTestSupport` package, so
/// `NCMailCoreTests` can depend on it without the package cycle that `NCMailCore` would hit
/// depending on the full `NCMailTestSupport` product. ADR-0026 (supersedes ADR-0022, which
/// resolved the same fixture directory by walking up from `#filePath`).
enum Fixture {
    static func data(_ name: String) throws -> Data {
        try FixtureBytes.data(name)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try FixtureBytes.decode(type, from: name)
    }
}
