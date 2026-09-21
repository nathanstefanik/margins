import Foundation
import Testing
import MarginsCore
import MarginsModel

@Suite("EpubMirror")
struct EpubMirrorTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-epub-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("fill from a fixture EPUB named by its hash, then remove")
    func fillHasAndRemove() throws {
        let fixture = try #require(try fixtureEpubs().first)
        let bookId = try Library.contentID(ofFile: fixture)
        let root = try tempRoot()
        let mirror = EpubMirror(root: root)

        try mirror.fill(bookId: bookId, from: fixture)
        #expect(mirror.has(bookId))
        try mirror.fill(bookId: bookId, from: fixture)

        let dest = URL(fileURLWithPath: mirror.path(for: bookId))
        let values = try dest.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        mirror.remove(bookId)
        #expect(!mirror.has(bookId))
    }

    @Test("a wrong id throws and leaves nothing under the root")
    func wrongIdLeavesNothing() throws {
        let fixture = try #require(try fixtureEpubs().first)
        let root = try tempRoot()
        let mirror = EpubMirror(root: root)

        do {
            try mirror.fill(bookId: "not-the-hash", from: fixture)
            Issue.record("expected a hash mismatch")
        } catch let error as CoreError {
            #expect(error == .library("mirror hash mismatch"))
        } catch {
            Issue.record("expected CoreError.library, got \(error)")
        }

        let leftover = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        #expect(leftover.isEmpty)
        #expect(!mirror.has("not-the-hash"))
    }
}
