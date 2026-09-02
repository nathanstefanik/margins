// swift-tools-version:6.0
import PackageDescription
import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // macos/
    .deletingLastPathComponent() // repo root
let rustLibDir = repoRoot.appendingPathComponent("target/release").path

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
        .macOS(.v14)
    ],
    targets: [
        // Header-only C target carrying the UniFFI-generated FFI header and
        // module map. The target name must stay `margins_ffiFFI`: the
        // generated Swift bindings do `#if canImport(margins_ffiFFI)`.
        .target(name: "margins_ffiFFI"),
        // Generated bindings (Sources/MarginsCore/Generated/) plus hand
        // written ergonomic wrappers. Statically linked against the Rust
        // staticlib in the workspace's target/release: ld prefers a dylib
        // when both exist, so pass the archive path directly to keep the
        // binaries self-contained.
        .target(
            name: "MarginsCore",
            dependencies: ["margins_ffiFFI"],
            swiftSettings: [
                // UniFFI 0.29 generated code is not strict-concurrency clean.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags(["\(rustLibDir)/libmargins_ffi.a"]),
                // zip -> xz2 / bzip2 need liblzma / libbz2 (both in the SDK)
                .linkedLibrary("lzma"),
                .linkedLibrary("bz2")
            ]
        ),
        .executableTarget(
            name: "Margins",
            dependencies: ["MarginsCore", "MarginsModel"],
            resources: [
                // Vendored epub.js renderer (see docs/macos-plan.md Part II).
                .copy("Resources/reader")
            ]
        ),
        // UI-agnostic model layer for the library browser (import, remove,
        // selection, errors). Separate target so MarginsTests can unit-test
        // it without touching SwiftUI.
        .target(
            name: "MarginsModel",
            dependencies: ["MarginsCore"]
        ),
        // Swift Testing tests. This is an executable rather than a
        // .testTarget because SwiftPM 6.3.2 on this CLT-only machine links
        // test bundles but never invokes the runner ("swift test" silently
        // exits 0 without running anything). The executable calls
        // Testing.__swiftPMEntryPoint() itself; revisit if the toolchain
        // bug is fixed or full Xcode (xcodebuild) becomes available.
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
