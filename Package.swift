// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FleetView",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        // The audit engine is deliberately a separate, UI-free target: Foundation only, no SwiftUI,
        // no AppKit, no AppState. That keeps it unit-testable without launching an app, and enforces
        // the architectural rule that logging never reaches up into the view layer.
        .target(
            name: "FleetViewAudit",
            path: "Sources/FleetViewAudit"
        ),
        // The file window's logic that does not need a window: reading and writing text exactly,
        // the read-only git runner and its parsers, quick-open matching. Foundation only, like the
        // audit engine, so the test executable can exercise it without an app.
        .target(
            name: "FleetViewFiles",
            path: "Sources/FleetViewFiles"
        ),
        .executableTarget(
            name: "FleetView",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "FleetViewAudit",
                "FleetViewFiles",
            ],
            path: "Sources/FleetView"
        ),
        // Run with `swift run FleetViewAuditTests`.
        //
        // Not a `.testTarget`: this machine has Command Line Tools but no full Xcode, so SwiftPM
        // can reach neither XCTest nor swift-testing and `swift test` fails outright. The suite is
        // therefore a plain executable with a small XCTest-compatible shim (see TestHarness.swift),
        // which keeps the tests runnable here and one edit away from real XCTest later.
        .executableTarget(
            name: "FleetViewAuditTests",
            dependencies: ["FleetViewAudit", "FleetViewFiles"],
            path: "Tests/FleetViewAuditTests"
        ),
    ]
)
