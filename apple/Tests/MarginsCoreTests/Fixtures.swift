import Foundation
import Testing

/// Files under `Tests/MarginsCoreTests/Fixtures/`, copied into the test
/// bundle. Most of them were written by the Rust core before it was deleted
/// (docs/apple-only-plan.md Phase 2 step 3) and act as golden files: the
/// Swift core must read them and re-emit them unchanged.
enum Fixtures {
    static func url(_ path: String) throws -> URL {
        let root = Bundle.module.resourceURL?.appendingPathComponent("Fixtures")
        guard let candidate = root?.appendingPathComponent(path),
              FileManager.default.fileExists(atPath: candidate.path)
        else {
            throw FixtureError.missing(path)
        }
        return candidate
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    /// A writable copy of a fixture directory, so tests can mutate it.
    static func copiedDirectory(_ path: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: url(path), to: destination)
        return destination
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case let .missing(path): return "fixture not found: \(path)"
            }
        }
    }
}

/// Timestamps and mark ids are generated at write time, so golden
/// comparisons normalize them exactly as the parity harness does
/// (docs/apple-only-plan.md Phase 2 step 6).
extension String {
    var normalizingGeneratedValues: String {
        var result = replacing(
            /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})/,
            with: "<TS>"
        )
        result = result.replacing(/\bid=[0-9a-hjkmnp-tv-z]{10}\b/, with: "id=<ID>")
        return result
    }
}
