import Foundation
@testable import MarginsKernel
import Testing

/// The coordination layer for the core's documents. `NSFileCoordinator`
/// works fine over plain local files, so the coordinated branch is
/// exercised against a fake container root — the real ubiquity path only
/// differs in that the accessor URL may point elsewhere, which these tests
/// already handle by always using the URL the accessor receives.
@Suite("FileStore", .serialized)
struct FileStoreTests {
    private static func tempDir(_ label: String) -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-filestore-\(label)-\(UUID().uuidString)", isDirectory: true)
            .path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// No ubiquity container: everything is the plain passthrough, whatever
    /// the platform actually resolves.
    private static func useNoContainer() {
        FileStore.overrideContainerProvider { nil }
    }

    /// A fake container root, so paths under it take the coordinated branch
    /// without needing iCloud.
    private static func useFakeContainer() -> String {
        let container = tempDir("container")
        FileStore.overrideContainerProvider {
            URL(fileURLWithPath: container, isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        }
        return container.appendingPathComponent("Documents")
    }

    @Test("membership follows the resolved container root")
    func membership() {
        let root = Self.useFakeContainer()
        #expect(FileStore.isCoordinated(root))
        #expect(FileStore.isCoordinated(root.appendingPathComponent("Library/books/abc/meta.json")))
        #expect(!FileStore.isCoordinated("/tmp/outside/meta.json"))
    }

    @Test("outside the container the calls are a plain passthrough")
    func passthrough() throws {
        Self.useNoContainer()
        let dir = Self.tempDir("plain")
        let path = dir.appendingPathComponent("meta.json")
        #expect(!FileStore.isCoordinated(path))

        try FileStore.writeData(Data("hello".utf8), to: path)
        #expect(FileStore.exists(path))
        #expect(try FileStore.read(path) == "hello")

        try FileStore.rename(path, to: dir.appendingPathComponent("renamed.json"))
        #expect(!FileStore.exists(path))
        #expect(try FileStore.read(dir.appendingPathComponent("renamed.json")) == "hello")

        try FileStore.remove(dir.appendingPathComponent("renamed.json"))
        #expect(!FileStore.exists(dir.appendingPathComponent("renamed.json")))
    }

    @Test("coordinated writes, reads, renames, and removals round-trip")
    func coordinatedRoundTrip() throws {
        let root = Self.useFakeContainer()
        let bookDir = root.appendingPathComponent("Library/books/abc")
        try Files.createDirectory(bookDir.appendingPathComponent("notes/chapters"))
        let path = bookDir.appendingPathComponent("meta.json")

        try FileStore.writeData(Data("content".utf8), to: path)
        #expect(try FileStore.readData(path) == Data("content".utf8))
        #expect(try FileStore.read(path) == "content")

        let renamed = bookDir.appendingPathComponent("position.json")
        try FileStore.rename(path, to: renamed)
        #expect(!FileStore.exists(path))
        #expect(try FileStore.read(renamed) == "content")

        try FileStore.remove(renamed)
        #expect(!FileStore.exists(renamed))
    }

    @Test("an evicted placeholder counts as existing but fails to read")
    func evictedPlaceholder() throws {
        let root = Self.useFakeContainer()
        let dir = root.appendingPathComponent("Library/books/abc/notes/chapters")
        try Files.createDirectory(dir)

        // The on-disk form of an evicted item: a .<name>.icloud placeholder
        // beside the logical path, no logical file.
        let placeholder = dir.appendingPathComponent(".001-note.md.icloud")
        try Data("placeholder".utf8).write(to: URL(fileURLWithPath: placeholder))
        let logical = dir.appendingPathComponent("001-note.md")

        #expect(FileStore.exists(logical))
        #expect(FileStore.isFile(logical))
        #expect(!Files.exists(logical), "plain fileExists misses the evicted item")

        // Reading still needs the content; without a real sync engine the
        // error surfaces like any other read failure.
        #expect(throws: (Error).self) { try FileStore.read(logical) }

        // A directory listing reports the logical name, so clears and
        // counts see the note.
        let listed = try FileStore.contents(ofDirectory: dir)
        #expect(listed == [logical])

        // Removal clears the placeholder: a cleared note must not survive
        // its own eviction.
        try FileStore.remove(logical)
        #expect(!FileStore.exists(logical))
        #expect(!Files.exists(placeholder))
    }

    @Test("placeholder entries outside the container are left alone")
    func placeholderOnlyInsideContainer() throws {
        Self.useNoContainer()
        let dir = Self.tempDir("outside-placeholder")
        let placeholder = dir.appendingPathComponent(".001-note.md.icloud")
        try Data("placeholder".utf8).write(to: URL(fileURLWithPath: placeholder))
        let logical = dir.appendingPathComponent("001-note.md")

        // Without a container the placeholder is just a file: the core's
        // tolerance for exotic filenames, not iCloud semantics.
        #expect(!FileStore.exists(logical))
        #expect(FileStore.exists(placeholder))
        #expect(try FileStore.contents(ofDirectory: dir) == [placeholder])
    }
}
