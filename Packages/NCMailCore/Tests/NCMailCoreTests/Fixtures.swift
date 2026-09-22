// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Reads the recorded fixtures off disk.
///
/// Not `Bundle.module`, which is how `docs/delivery/testing-strategy.md`
/// describes it: `NCMailTestSupport` depends on `NCMailCore`, so `NCMailCore`
/// cannot depend back on it without a package cycle. The path is resolved from
/// `#filePath`, which SwiftPM fixes at compile time. ADR-0022.
enum Fixture {
    static let directory: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "Packages/NCMailTestSupport/Sources/NCMailTestSupport/Resources/Fixtures")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
