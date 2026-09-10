// swift-tools-version:6.2
import PackageDescription

// Shared Apple package: one core, two frontends. MarginsCore/MarginsModel
// are platform-agnostic (macOS + iOS); the Margins executable is the macOS
// app, the iOS app is built from apple/ios/Margins.xcodeproj against the
// MarginsCore/MarginsModel products.

// During the Swift-core port (docs/apple-only-plan.md Phase 2) the package
// temporarily carries both the UniFFI bridge (MarginsFFI + margins_ffiFFI +
// the generated bindings) and, from step 2 on, the hand-written core under
// the temporary module name MarginsKernel. The bridge targets are deleted in
// step 7; MarginsKernel is renamed MarginsCore then.

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
        // EPUB archive reading/writing for the Swift core (step 2+).
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        // UniFFI static archive, assembled per platform by
        // scripts/build-core.sh (macOS slice) and
        // scripts/build-xcframework.sh (iOS slices). Consumed as a
        // binaryTarget with per-platform slices, replacing the old
        // .unsafeFlags link of target/release/libmargins_ffi.a — an
        // absolute macOS-only path could never carry iOS architectures.
        // SwiftPM links the archive into dependents but does not expose
        // headers from binary targets, so the `margins_ffiFFI` module the
        // generated bindings import still comes from the C target below.
        // (Deleted in Phase 2 step 7.)
        .binaryTarget(name: "MarginsFFI", path: "../build/MarginsFFI.xcframework"),
        // Header-only C target carrying the UniFFI-generated FFI header and
        // module map. The target name must stay `margins_ffiFFI`: the
        // generated Swift bindings do `#if canImport(margins_ffiFFI)`.
        .target(name: "margins_ffiFFI"),
        // Generated bindings (Sources/MarginsCore/Generated/) plus hand
        // written ergonomic wrappers, statically linked against the Rust
        // staticlib inside the xcframework. liblzma / libbz2 satisfy the
        // zip -> xz2 / bzip2 C dependencies (both in the SDK).
        .target(
            name: "MarginsCore",
            dependencies: ["margins_ffiFFI", "MarginsFFI"],
            swiftSettings: [
                // UniFFI 0.29 generated code is not strict-concurrency clean.
                // Dies with the bridge in Phase 2 step 7; everything else is
                // Swift 6 mode.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("lzma"),
                .linkedLibrary("bz2")
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
        // The hand-written Swift core, under its temporary name while the
        // UniFFI bridge still owns `MarginsCore` (step 7 renames it).
        .target(
            name: "MarginsKernel",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // Tests for the hand-written Swift core (step 2+). Grows the
        // Fixtures resource bundle when the ported fixtures land in step 3.
        // Still depends on MarginsCore for the bridge smoke test, which
        // goes away with the bridge.
        .testTarget(
            name: "MarginsCoreTests",
            dependencies: ["MarginsCore", "MarginsKernel"]
        ),
    ]
)
