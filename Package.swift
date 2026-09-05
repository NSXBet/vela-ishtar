// swift-tools-version:6.0
// Package.swift
// Repo root of aihub-menu-bar (Vela Ishtar).
// Declares the SwiftPM package. WP-00 (item 00.3) made the app sources
// integration-testable: the SwiftPM target "VelaCore" now compiles the
// COMBINED module — Sources/VelaCore plus Sources/App minus main.swift
// (the only top-level-code entry point) — mirroring build.sh's single-module
// swiftc invocation exactly. One source set, one module, named VelaCore so
// the existing test suites' `@testable import VelaCore` stays valid; there
// is no separate app module to drift out of sync with the shipped binary.
// build.sh remains the authoritative app build; SwiftPM's copy of the same
// files exists so VelaAppTests can drive app sources with injected fakes.
// All targets pin swiftLanguageMode(.v5): the shipped app builds under
// Swift 5 semantics (its dispatch-based completion handlers hard-error in
// Swift 6 mode), while Swift 6-defaulting toolchains stay usable for
// `swift test` / `swift build`. build.sh passes the matching -swift-version 5.
// RELEVANT FILES: build.sh, Makefile, Sources/VelaCore/UsageContracts.swift,
// Tests/VelaAppTests/TestSupport.swift

import PackageDescription

let package = Package(
    name: "VelaIshtar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VelaCore",
            path: "Sources",
            exclude: ["App/main.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VelaAppTests",
            dependencies: ["VelaCore"],
            path: "Tests/VelaAppTests",
            resources: [
                .copy("../Fixtures/usage")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VelaCoreTests",
            dependencies: ["VelaCore"],
            path: "Tests/VelaCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
