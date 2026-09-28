// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hookling",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: sprite geometry, animation timing, state machine, session
        // merging, wire format. No AppKit, no I/O, no globals — so it is fully
        // unit-testable and can be checked under strict concurrency.
        .target(
            name: "HooklingCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The pet itself. Swift 5 language mode: AppKit delegates and
        // DispatchSource callbacks predate strict Sendable checking, and
        // everything here is main-thread-confined by construction.
        .executableTarget(
            name: "Hookling",
            dependencies: ["HooklingCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Debug + hook client. Talks the same socket protocol as the app.
        .executableTarget(
            name: "hooklingctl",
            dependencies: ["HooklingCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "HooklingCoreTests",
            dependencies: ["HooklingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
