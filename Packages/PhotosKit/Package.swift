// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "PhotosKit",
    defaultLocalization: "en",
    platforms: [.iOS("27.0"), .macOS("27.0"), .visionOS("27.0"), .tvOS("27.0"), .watchOS("27.0")],
    products: [
        .library(name: "PhotosModel", targets: ["PhotosModel"]),
        .library(name: "PhotosDomain", targets: ["PhotosDomain"]),
        .library(name: "PhotosNetworking", targets: ["PhotosNetworking"]),
        .library(name: "PhotosStore", targets: ["PhotosStore"]),
        .library(name: "PhotosMedia", targets: ["PhotosMedia"]),
        .library(name: "PhotosBackup", targets: ["PhotosBackup"]),
        .library(name: "PhotosCore", targets: ["PhotosCore"]),
        .library(name: "PhotosAppUI", targets: ["PhotosAppUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        // Value types, identifiers, feature flags. No I/O.
        .target(name: "PhotosModel", swiftSettings: swiftSettings),
        // Pure algorithms ported from the web app (grouping, stacks, memories, duplicates, search parsing).
        .target(name: "PhotosDomain", dependencies: ["PhotosModel"], resources: [.process("Resources")], swiftSettings: swiftSettings),
        // HTTP, WebDAV, OCS, login, feature detection, on the app's own URLSession client.
        .target(
            name: "PhotosNetworking",
            dependencies: ["PhotosModel"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        // GRDB schema, queries, sync engine, outbox.
        .target(
            name: "PhotosStore",
            dependencies: ["PhotosModel", "PhotosDomain", "PhotosNetworking", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: swiftSettings
        ),
        // Preview cache, image pipeline, video and Live Photo loading, editing.
        .target(
            name: "PhotosMedia",
            dependencies: ["PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        // PhotoKit scanning, reconciliation against the server, upload engine.
        .target(
            name: "PhotosBackup",
            dependencies: [
                "PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore", "PhotosMedia",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        // Composition root: accounts, keychain, per-account services, settings.
        .target(
            name: "PhotosCore",
            dependencies: [
                "PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore", "PhotosMedia", "PhotosBackup",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        // Shared SwiftUI components, grid, viewer, screens.
        .target(
            name: "PhotosAppUI",
            dependencies: ["PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore", "PhotosMedia", "PhotosBackup", "PhotosCore"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),

        .testTarget(name: "PhotosModelTests", dependencies: ["PhotosModel"], swiftSettings: swiftSettings),
        .testTarget(name: "PhotosDomainTests", dependencies: ["PhotosDomain"], swiftSettings: swiftSettings),
        .testTarget(
            name: "PhotosNetworkingTests",
            dependencies: ["PhotosNetworking"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PhotosStoreTests",
            dependencies: ["PhotosStore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "PhotosMediaTests", dependencies: ["PhotosMedia", "PhotosDomain"], swiftSettings: swiftSettings),
        .testTarget(
            name: "PhotosCoreTests",
            dependencies: [
                "PhotosCore", "PhotosModel", "PhotosNetworking", "PhotosStore", "PhotosBackup",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "PhotosAppUITests", dependencies: ["PhotosAppUI"], swiftSettings: swiftSettings),
        .testTarget(
            name: "PhotosBackupTests", dependencies: ["PhotosBackup", "PhotosStore", "PhotosNetworking"], swiftSettings: swiftSettings),
    ]
)
