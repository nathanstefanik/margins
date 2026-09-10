import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // MarginsModelTests/
    .deletingLastPathComponent() // Tests/
    .deletingLastPathComponent() // apple/
    .deletingLastPathComponent() // repo root

/// A fresh, empty data directory for one test.
func makeTempDataDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("margins-macos-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

/// Every example book in `fixtures/*.epub` at the repo root.
func fixtureEpubs() throws -> [String] {
    let fixtures = repoRoot.appendingPathComponent("fixtures", isDirectory: true)
    return try FileManager.default
        .contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "epub" }
        .map { $0.path }
        .sorted()
}
