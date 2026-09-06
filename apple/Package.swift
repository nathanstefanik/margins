// swift-tools-version:6.0
import PackageDescription

// Shared Apple package: one core, two frontends. MarginsCore/MarginsModel
// are platform-agnostic (macOS + iOS); the Margins executable is the macOS
// app, MarginsIOS the iOS app (Phase 4 wires the real scenes; see
// docs/ios-plan.md).

// This machine has Command Line Tools only (no full Xcode). The Swift
// Testing framework ships with the CLT but SwiftPM only adds it via -I,
// which does not resolve framework modules; pass -F explicitly.
// https://github.com/swiftlang/swift-package-manager/issues/8285
let cltDeveloperFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
// Home of lib_TestingInterop.dylib, which Testing.framework loads via @rpath.
let cltDeveloperLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Margins",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    // Library products consumed by the iOS app's Xcode project
    // (apple/ios/Margins.xcodeproj); the macOS app links the targets
    // directly from within the package.
    products: [
        .library(name: "MarginsCore", targets: ["MarginsCore"]),
        .library(name: "MarginsModel", targets: ["MarginsModel"]),
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
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("lzma"),
                .linkedLibrary("bz2")
            ]
        ),
        .executableTarget(
            name: "Margins",
            dependencies: ["MarginsCore", "MarginsModel"]
        ),
        // UI-agnostic model layer for the library browser (import, remove,
        // selection, errors). Separate target so MarginsTests can unit-test
        // it without touching SwiftUI. Carries the vendored epub.js reader
        // bundle + scheme handler so both Apple apps serve identical
        // reader assets.
        .target(
            name: "MarginsModel",
            dependencies: ["MarginsCore"],
            resources: [
                // Vendored epub.js renderer (see docs/architecture.md).
                .copy("Resources/reader")
            ]
        ),
        // Swift Testing tests. This is an executable rather than a
        // .testTarget because SwiftPM 6.3.2 on this CLT-only machine links
        // test bundles but never invokes the runner ("swift test" silently
        // exits 0 without running anything). The executable calls
        // Testing.__swiftPMEntryPoint() itself; revisit once full Xcode
        // (xcodebuild test) is available — do not break `make mac-test`.
        .executableTarget(
            name: "MarginsTests",
            dependencies: ["MarginsCore", "MarginsModel"],
            swiftSettings: [
                .unsafeFlags(["-F\(cltDeveloperFrameworks)"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltDeveloperFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltDeveloperFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltDeveloperLib,
                    "-Xlinker", "-framework", "-Xlinker", "Testing"
                ])
            ]
        )
    ]
)
