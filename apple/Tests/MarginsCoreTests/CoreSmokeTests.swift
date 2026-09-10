import Foundation
import MarginsCore
import Testing

/// Keeps the UniFFI bridge linkable and functional while it coexists with
/// the Swift core (docs/apple-only-plan.md Phase 2). Deleted with the bridge
/// in step 7; the apps' `CoreStore` actor lives in MarginsKernel now.
@Suite("Core smoke")
struct CoreSmokeTests {
    @Test("the bridge module links and the FFI core opens")
    func storeOpens() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let core = try MarginsCore(dataDir: dir.path)
        let root = try await core.libraryRoot()
        #expect(!root.isEmpty)
    }
}
