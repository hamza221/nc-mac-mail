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
// Test-only. The app target must never depend on this package: it exists
// because a SwiftPM test target cannot read files outside its own package, and
// the recorded fixtures are shared by every package's tests. WS-14 fills it.
let package = Package(
    name: "NCMailTestSupport",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NCMailTestSupport", targets: ["NCMailTestSupport"])
    ],
    dependencies: [
        .package(path: "../NCMailCore"),
        .package(path: "../NCMailNet"),
        .package(path: "../NCMailStore"),
    ],
    targets: [
        .target(
            name: "NCMailTestSupport",
            dependencies: ["NCMailCore", "NCMailNet", "NCMailStore"],
            // `.copy`, not `.process`: a recorded fixture is a byte-for-byte
            // record of what the server sent, and `.process` would flatten the
            // directory tree the recorder writes.
            resources: [.copy("Resources/Fixtures")],
            swiftSettings: shared
        ),
        .testTarget(
            name: "NCMailTestSupportTests",
            dependencies: ["NCMailTestSupport"],
            swiftSettings: shared
        ),
    ]
)
