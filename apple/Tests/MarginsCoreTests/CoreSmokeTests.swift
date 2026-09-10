import Foundation
import MarginsCore
import Testing

/// Placeholder while the core port is in flight
/// (docs/apple-only-plan.md Phase 2 step 3 replaces this with the
/// translated per-module suites).
@Suite("Core smoke")
struct CoreSmokeTests {
    @Test("the bridge module links and a store opens")
    func storeOpens() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try CoreStore(dataDir: dir.path)
        let root = try await store.libraryRoot()
        #expect(!root.isEmpty)
    }
}
