// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

@Suite("Update channel")
struct UpdateChannelTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "updates-\(UUID().uuidString)"))
    }

    /// An empty bundle whose only job is to report `version` as its marketing version.
    private func bundle(version: String) throws -> Bundle {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "updates-\(UUID().uuidString).app", directoryHint: .isDirectory)
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return try #require(Bundle(url: url))
    }

    @Test func aPreReleaseStartsOnBetaAndAReleaseOnStable() throws {
        #expect(AppUpdater(bundle: try bundle(version: "0.4.0-beta"), defaults: defaults).channel == .beta)
        let other = try #require(UserDefaults(suiteName: "updates-\(UUID().uuidString)"))
        #expect(AppUpdater(bundle: try bundle(version: "0.4.0"), defaults: other).channel == .stable)
    }

    /// The regression: the starting channel used to be re-derived from the running version on
    /// every launch, so a beta tester who updated to a stable build dropped off beta.
    @Test func aBetaTesterWhoUpdatesToStableStaysOnBeta() throws {
        _ = AppUpdater(bundle: try bundle(version: "0.4.0-beta"), defaults: defaults)
        #expect(AppUpdater(bundle: try bundle(version: "0.4.0"), defaults: defaults).channel == .beta)
    }

    @Test func aChosenChannelOutlivesTheVersion() throws {
        AppUpdater(bundle: try bundle(version: "0.4.0"), defaults: defaults).channel = .beta
        #expect(AppUpdater(bundle: try bundle(version: "0.5.0"), defaults: defaults).channel == .beta)
    }
}
