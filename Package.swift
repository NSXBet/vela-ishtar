// swift-tools-version:6.0
// Package.swift
// Repo root of aihub-menu-bar (Vela Ishtar).
// Declares the SwiftPM package: a pure-Foundation VelaCore library plus its
// test target. Sources/App (AppKit UI) is intentionally NOT a SwiftPM target
// so `swift test` never needs AppKit — build.sh compiles App alongside
// VelaCore for the actual .app binary.
// RELEVANT FILES: build.sh, Sources/VelaCore/*.swift, Tests/VelaCoreTests/*.swift

import PackageDescription

let package = Package(
    name: "VelaIshtar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VelaCore",
            path: "Sources/VelaCore"
        ),
        .testTarget(
            name: "VelaCoreTests",
            dependencies: ["VelaCore"],
            path: "Tests/VelaCoreTests"
        ),
    ]
)
