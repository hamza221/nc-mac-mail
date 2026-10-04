// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NextcloudMail

/// The app target is also the test host: `NextcloudMailApp` runs before any suite does.
/// These pin the guard that keeps that launch inert (ADR-0103), because its regression is
/// invisible in CI and very visible on a developer's machine: a Keychain consent prompt per
/// rebuild (ADR-0054), and engines syncing a real account underneath every suite.
struct TestHostTests {
    /// This test runs inside the host, so the detection must answer yes here of all places.
    @Test func aHostedRunIsDetectedFromInsideOne() {
        #expect(NextcloudMailApp.isHostingTests)
    }

    /// The store a hosted launch opens never touches the disk — zero bytes is the in-memory
    /// mirror's signature — and it is not the "temporary" fallback, which would make the
    /// host's window offer a mirror reset no user asked for.
    @Test func aHostedLaunchOpensAnInMemoryMirror() {
        let (store, isTemporary) = NextcloudMailApp.openStore()
        #expect(store.fileSizeOnDisk() == 0)
        #expect(!isTemporary)
    }
}
