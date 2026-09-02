import Foundation
import Testing
import MarginsCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // MarginsTests/
    .deletingLastPathComponent() // Tests/
    .deletingLastPathComponent() // macos/
    .deletingLastPathComponent() // repo root

private func makeTempDataDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("margins-macos-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

private func fixtureEpubs() throws -> [String] {
    let fixtures = repoRoot.appendingPathComponent("fixtures", isDirectory: true)
    return try FileManager.default
        .contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "epub" }
        .map { $0.path }
        .sorted()
}

@Suite("MarginsCore bridge")
struct BridgeTests {
    @Test("dataDir is honored")
    func dataDirIsHonored() async throws {
        let dir = try makeTempDataDir()
        let store = try CoreStore(dataDir: dir)
        let resolved = try await store.dataDir()
        #expect(resolved == dir)
    }

    @Test("import through the bridge agrees with the stored metadata")
    func importAgreesWithStoredMetadata() async throws {
        let fixtures = try fixtureEpubs()
        #expect(!fixtures.isEmpty, "expected at least one fixtures/*.epub to exercise the bridge")

        for fixture in fixtures {
            let store = try CoreStore(dataDir: try makeTempDataDir())

            let imported = try await store.importEpub(atPath: fixture)
            #expect(!imported.title.isEmpty)
            #expect(!imported.author.isEmpty)
            #expect(!imported.chapters.isEmpty)

            // Reading back through a second bridge call must agree with the
            // import-time parse (same contract as the core integration test).
            let reread = try await store.getBook(id: imported.id)
            #expect(reread.title == imported.title)
            #expect(reread.author == imported.author)
            #expect(reread.chapters.count == imported.chapters.count)

            let summaries = try await store.listBooks()
            #expect(summaries.count == 1)
            #expect(summaries.first?.id == imported.id)
            #expect(summaries.first?.chapterCount == UInt32(imported.chapters.count))
        }
    }
}
