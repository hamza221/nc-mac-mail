// swift-tools-version: 6.2
//
// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import PackageDescription

// The same five settings appear in all five manifests. ADR-0013 accepted that
// duplication: a shared settings file would have to be a package of its own,
// and SwiftPM cannot import one manifest from another.
//
// `defaultIsolation(MainActor.self)` is deliberately absent. The library sets
// it because it is a UI package; here it would drag every database write and
// every backfill request onto the main actor. See docs/architecture/concurrency.md.
// Warnings-as-errors is NOT here, and that is deliberate. Xcode hands every
// package target `-suppress-warnings`, and swiftc refuses that together with
// the `-warnings-as-errors` that `.treatAllWarnings(as: .error)` produces:
// "error: conflicting options". Nothing in the .xcodeproj can clear the
// suppression, so the app would not build at all. `swift build -Xswiftc
// -warnings-as-errors` applies the flag to the root package's own targets and
// not to its dependencies, which is exactly the scope wanted -- so the Makefile
// and CI pass it and the manifests stay quiet. ADR-0016.
let shared: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "NCMailCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NCMailCore", targets: ["NCMailCore"])
    ],
    targets: [
        .target(name: "NCMailCore", swiftSettings: shared),
        .testTarget(name: "NCMailCoreTests", dependencies: ["NCMailCore"], swiftSettings: shared),
    ]
)
