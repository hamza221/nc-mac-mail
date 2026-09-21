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
    name: "NCMailSync",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NCMailSync", targets: ["NCMailSync"])
    ],
    dependencies: [
        .package(path: "../NCMailCore"),
        .package(path: "../NCMailNet"),
        .package(path: "../NCMailStore"),
    ],
    targets: [
        // The only target that sees both NCMailNet and NCMailStore. That is the
        // point of the layout: nothing below here can turn a response into a view.
        .target(
            name: "NCMailSync",
            dependencies: ["NCMailCore", "NCMailNet", "NCMailStore"],
            swiftSettings: shared
        ),
        .testTarget(name: "NCMailSyncTests", dependencies: ["NCMailSync"], swiftSettings: shared),
    ]
)
