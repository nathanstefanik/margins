// swift-tools-version:6.2
import PackageDescription

// Shared Apple package: one core, two frontends. MarginsCore/MarginsModel
// are platform-agnostic (macOS + iOS); the Margins executable is the macOS
// app, the iOS app is built from apple/ios/Margins.xcodeproj against the
// MarginsCore/MarginsModel products.

let package = Package(
    name: "Margins",
    platforms: [
        .macOS(.v14),
        .iOS(.v26)
    ],
    // Library products consumed by the iOS app's Xcode project
    // (apple/ios/Margins.xcodeproj); the macOS app links the targets
    // directly from within the package.
    products: [
        .library(name: "MarginsCore", targets: ["MarginsCore"]),
        .library(name: "MarginsModel", targets: ["MarginsModel"]),
    ],
    dependencies: [
        // EPUB archive reading/writing for the core.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        // The core: models, EPUB parsing, library, notes, marks, compile,
        // search, and the `CoreStore` actor facade the apps drive.
        .target(
            name: "MarginsCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // UI-agnostic model layer for the library browser (import, remove,
        // selection, errors). Separate target so the test targets can
        // unit-test it without touching SwiftUI. Carries the vendored
        // epub.js reader bundle + scheme handler so both Apple apps serve
        // identical reader assets.
        .target(
            name: "MarginsModel",
            dependencies: ["MarginsCore"],
            resources: [
                // Vendored epub.js renderer (see docs/architecture.md).
                .copy("Resources/reader")
            ]
        ),
        .executableTarget(
            name: "Margins",
            dependencies: ["MarginsCore", "MarginsModel"]
        ),
        // Swift Testing tests for the model layer and the apps' shared
        // logic. Converted from a runner executable to a real test target
        // now that full Xcode runs `swift test` (docs/apple-only-plan.md
        // Phase 2 step 1).
        .testTarget(
            name: "MarginsModelTests",
            dependencies: ["MarginsCore", "MarginsModel"]
        ),
        // Tests for the core, including the read-compatibility fixture the
        // pre-Swift core wrote before the port (Fixtures/legacy-library/).
        .testTarget(
            name: "MarginsCoreTests",
            dependencies: ["MarginsCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
