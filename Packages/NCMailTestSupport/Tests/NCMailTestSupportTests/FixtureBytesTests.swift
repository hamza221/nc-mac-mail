// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import Testing

/// The recorder's promises, checked by machine instead of by a human running `grep` before
/// every commit.
///
/// `Scripts/record-fixtures.sh`'s own checklist says "grep the fixtures for your real domain
/// and your real addresses" — a step a person can forget. This suite makes forgetting it a
/// test failure instead.
@Suite("Fixture bytes")
struct FixtureBytesTests {
    @Test("every recorded fixture is reachable through Bundle.module")
    func loadsEveryFixture() throws {
        let names = try FixtureBytes.allNames()
        #expect(!names.isEmpty)
        // Emptiness is not an error: a 204 (thread summary and smartreply with LLM
        // processing off) and the avatar 404 genuinely have zero-byte bodies, and the
        // fixture records what the server sent. Loadability is the invariant.
        for name in names {
            _ = try FixtureBytes.data(name)
        }
    }

    // The recorder's own checklist, as an assertion. These four strings are the operator's
    // Nextcloud login, real name, and mail domains from the account the fixtures were
    // recorded against — see the constraints in the WS-14 brief. None of them has any
    // business surviving the scrubber.
    private static let forbiddenSubstrings = ["hamza", "mahjoubi", "nextdev", "nodarx", "nextcloud.local"]

    @Test("no fixture leaks the real account's name, login or mail domain")
    func fixturesAreScrubbed() throws {
        for name in try FixtureBytes.allNames() {
            let text = String(decoding: try FixtureBytes.data(name), as: UTF8.self).lowercased()
            for forbidden in Self.forbiddenSubstrings {
                #expect(!text.contains(forbidden), "\(name) contains \"\(forbidden)\"")
            }
        }
    }

    // Server internals the recorder strips: a debug-mode JSON error's PHP stack, the
    // install path, and the live session cookies a DAV response's headers carry.
    private static let forbiddenServerInternals = [
        "\"trace\"", "/var/www/", "set-cookie", "oc_sessionpassphrase", "x-request-id", "x-debug-token",
    ]

    @Test("no fixture carries a stack trace, an install path or a session cookie")
    func fixturesCarryNoServerInternals() throws {
        for name in try FixtureBytes.allNames() {
            let text = String(decoding: try FixtureBytes.data(name), as: UTF8.self).lowercased()
            for forbidden in Self.forbiddenServerInternals {
                #expect(!text.contains(forbidden), "\(name) contains \"\(forbidden)\"")
            }
        }
    }

    @Test("the error fixtures are named for what the server actually sent")
    func errorFixturesAreHonestlyNamed() throws {
        // 403 with an empty array, not the 404 the old names implied. See
        // docs/reference/api-payloads.md#what-a-missing-thing-actually-answers.
        for name in ["error-mailbox-forbidden.json", "error-message-forbidden.json"] {
            let body = String(decoding: try FixtureBytes.data(name), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(body == "[]")
        }
        // A genuine 404, but a zero-byte text/html body, not JSON.
        #expect(try FixtureBytes.data("avatar-404.txt").isEmpty)
    }

    @Test("a missing fixture reports its own name")
    func missingFixtureIsDescriptive() {
        #expect(throws: FixtureBytes.FixtureError.self) {
            _ = try FixtureBytes.data("does-not-exist.json")
        }
    }
}
