import Testing

/// SwiftPM's test runner is broken on this toolchain (see Package.swift), so
/// this executable invokes the Swift Testing entry point directly and exits
/// with its status. Run with `swift run MarginsTests`.
@main
struct MarginsTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
