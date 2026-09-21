import Testing
import Foundation
import MarginsCore
import MarginsModel

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

    @Test("evicted placeholder detection matches the .name.icloud sibling")
    func evictedPlaceholderDetection() throws {
        let dir = tempDirectory()
        let logical = dir.appendingPathComponent("cover.jpg")
        #expect(!LibraryLocation.hasEvictedPlaceholder(for: logical))

        // iCloud's eviction naming: a hidden `.<name>.icloud` beside the
        // logical path, which itself disappears.
        let placeholder = dir.appendingPathComponent(".cover.jpg.icloud")
        try Data([0x00]).write(to: placeholder)
        #expect(LibraryLocation.hasEvictedPlaceholder(for: logical))
    }

    @Test("availability distinguishes local, evicted, and missing paths")
    func availability() throws {
        let dir = tempDirectory()
        let local = dir.appendingPathComponent("cover.jpg")
        try Data([0xFF]).write(to: local)
        #expect(LibraryLocation.availability(of: local.path) == .local)

        let evicted = dir.appendingPathComponent("source.epub")
        try Data([0x00]).write(to: dir.appendingPathComponent(".source.epub.icloud"))
        #expect(LibraryLocation.availability(of: evicted.path) == .evicted)

        let missing = dir.appendingPathComponent("nope.jpg")
        #expect(LibraryLocation.availability(of: missing.path) == .missing)
    }

    @Test("a placeholder-only path enters the download path and stays bounded")
    func placeholderPathIsBounded() async throws {
        // A local fixture cannot be a real ubiquity item: the download
        // start either throws (pass-through, the "no such item" case) or
        // the poll loop runs to its bounded limit and times out. Both are
        // correct; neither may hang or early-return as "missing".
        let location = LibraryLocation(
            containerProvider: { nil },
            documentsProvider: { tempDirectory() },
            downloadPollLimit: 3
        )
        let dir = tempDirectory()
        let logical = dir.appendingPathComponent("cover.jpg")
        try Data([0x00]).write(to: dir.appendingPathComponent(".cover.jpg.icloud"))
        do {
            let resolved = try await location.materializedPath(for: logical.path)
            #expect(resolved == logical.path)
        } catch {
            #expect(error is LibraryLocation.MaterializationError)
            #expect(error.localizedDescription.contains("cover.jpg"))
        }
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
