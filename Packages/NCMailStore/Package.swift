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
    name: "NCMailStore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NCMailStore", targets: ["NCMailStore"])
    ],
    dependencies: [
        .package(path: "../NCMailCore"),
        // ADR-0004. GRDB is the only third-party dependency in the storage layer.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "NCMailStore",
            dependencies: [
                "NCMailCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: shared
        ),
        .testTarget(name: "NCMailStoreTests", dependencies: ["NCMailStore"], swiftSettings: shared),
    ]
)
