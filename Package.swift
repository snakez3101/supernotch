// swift-tools-version: 6.2
// SuperNotch — see docs/SPEC.md §B for the target layout and the reasoning behind the settings below.
// FOUNDATION-OWNED FILE: streams must not edit it (SPEC §C "Shared files").
import PackageDescription

var products: [Product] = [
    .library(name: "SuperNotchCore", targets: ["SuperNotchCore"]),
    .executable(name: "supernotch-hook", targets: ["supernotch-hook"]),
]

var targets: [Target] = [
    // Pure logic + contract types. Foundation only, Swift 6 language mode, everything Sendable.
    // Builds and is tested on Linux AND macOS.
    .target(
        name: "SuperNotchCore",
        path: "Sources/SuperNotchCore"
    ),
    // Claude Code hook helper (`supernotch-hook`). Tiny, fail-open, must build on Linux too.
    .executableTarget(
        name: "supernotch-hook",
        dependencies: ["SuperNotchCore"],
        path: "Sources/supernotch-hook"
    ),
    .testTarget(
        name: "SuperNotchCoreTests",
        dependencies: ["SuperNotchCore"],
        path: "Tests/SuperNotchCoreTests",
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
    // The AppKit/SwiftUI app only exists when the manifest is evaluated on a Mac.
    // Swift 5 language mode + MainActor default isolation: we cannot type-check this target locally
    // (Linux has no AppKit/SwiftUI), so we trade strict concurrency *errors* for *warnings* and make
    // every declaration MainActor unless it says otherwise. Background work must be explicit
    // (`nonisolated`, `actor`, `Task.detached`, DispatchQueue). See SPEC §F "compile-safety checklist".
    products.append(.executable(name: "SuperNotch", targets: ["SuperNotch"]))
    targets.append(
        .executableTarget(
            name: "SuperNotch",
            dependencies: ["SuperNotchCore"],
            path: "Sources/SuperNotch",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
            ]
        )
    )
#endif

let package = Package(
    name: "SuperNotch",
    platforms: [.macOS("26.0")],
    products: products,
    dependencies: [],  // Deliberately none. Hotkeys use Carbon RegisterEventHotKey (SPEC §B).
    targets: targets
)
