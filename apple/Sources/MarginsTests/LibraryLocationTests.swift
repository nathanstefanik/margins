import Testing
import Foundation
import MarginsCore
@testable import MarginsModel

@Suite("LibraryLocation")
struct LibraryLocationTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-location-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("no ubiquity container falls back to local Documents/Library at runtime")
    func fallbackToLocalDocuments() {
        let documents = tempDirectory()
        let location = LibraryLocation(
            containerProvider: { nil },
            documentsProvider: { documents }
        )
        guard case .localDocuments(let path) = location.resolve() else {
            Issue.record("expected the local fallback")
            return
        }
        #expect(path == documents.appendingPathComponent("Library", isDirectory: true).path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("an available container resolves to its Documents/Library")
    func resolvesToContainer() {
        let container = tempDirectory()
        let location = LibraryLocation(
            containerProvider: { container },
            documentsProvider: { tempDirectory() }
        )
        guard case .iCloudDocuments(let path) = location.resolve() else {
            Issue.record("expected the iCloud container")
            return
        }
        #expect(path == container.appendingPathComponent("Library", isDirectory: true).path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("local files materialize as themselves")
    func localFilesPassThrough() async throws {
        let location = LibraryLocation(containerProvider: { nil }, documentsProvider: { tempDirectory() })
        let file = tempDirectory().appendingPathComponent("cover.jpg")
        try Data([0xFF]).write(to: file)
        let resolved = try await location.materializedPath(for: file.path)
        #expect(resolved == file.path)
    }

    @Test("missing files pass through so the core owns the not-found error")
    func missingFilesPassThrough() async throws {
        let location = LibraryLocation(containerProvider: { nil }, documentsProvider: { tempDirectory() })
        let missing = tempDirectory().appendingPathComponent("nope.jpg").path
        let resolved = try await location.materializedPath(for: missing)
        #expect(resolved == missing)
    }

    @Test("stagedCopy snapshots a picked file into a readable staging path")
    func stagedCopy() throws {
        let location = LibraryLocation(containerProvider: { nil }, documentsProvider: { tempDirectory() })
        let picked = tempDirectory().appendingPathComponent("book.epub")
        try Data("epub-bytes".utf8).write(to: picked)
        let staged = try location.stagedCopy(of: picked)
        #expect(staged.lastPathComponent == "book.epub")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "epub-bytes")
    }

    @Test("conflict detection is empty for plain files and missing paths")
    func conflictsEmptyWithoutICloud() {
        #expect(LibraryLocation.unresolvedConflictFileNames(at: "/nonexistent/note.md") == [])
    }
}
