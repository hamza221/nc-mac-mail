// swift-tools-version: 6.2
//
// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import PackageDescription

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
    name: "NCMailNet",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NCMailNet", targets: ["NCMailNet"])
    ],
    dependencies: [
        .package(path: "../NCMailCore"),
        // Test-only: the shared `FakeTransport`. `NCMailTestSupport` depends on `NCMailNet`
        // for the main target, and this is the reverse edge for the test target only — not a
        // cycle, because nothing depends on a test target. Verified empirically and recorded
        // in ADR-0026, which is also why `NCMailCoreTests`/`NCMailStoreTests` can do the same
        // thing for their own packages.
        .package(path: "../NCMailTestSupport"),
    ],
    targets: [
        .target(name: "NCMailNet", dependencies: ["NCMailCore"], swiftSettings: shared),
        .testTarget(
            name: "NCMailNetTests",
            dependencies: [
                "NCMailNet",
                .product(name: "NCMailTestSupport", package: "NCMailTestSupport"),
                .product(name: "NCMailFixtures", package: "NCMailTestSupport"),
            ],
            swiftSettings: shared
        ),
    ]
)
