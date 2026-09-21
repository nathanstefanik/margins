import Foundation
@testable import MarginsCore
import Testing

enum FileStoreTestIsolation {
    private static let lock = NSLock()

    static func begin() {
        lock.lock()
    }

    static func end() {
        FileStore.accessDeadline = 8
        FileStore.overrideContainerProvider(nil)
        lock.unlock()
    }
}

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
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let root = Self.useFakeContainer()
        #expect(FileStore.isCoordinated(root))
        #expect(FileStore.isCoordinated(root.appendingPathComponent("Library/books/abc/meta.json")))
        #expect(!FileStore.isCoordinated("/tmp/outside/meta.json"))
    }

    @Test("outside the container the calls are a plain passthrough")
    func passthrough() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
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
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
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

    @Test("an evicted read fails fast without touching the placeholder")
    func evictedPlaceholder() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
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

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try FileStore.read(logical)
            Issue.record("expected an evicted read to fail")
        } catch let error as CoreError {
            #expect(error == .notDownloaded(logical))
            #expect(error.message == "001-note.md has not downloaded from iCloud yet")
        } catch {
            Issue.record("expected CoreError, got \(error)")
        }
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(try Files.read(placeholder) == "placeholder")

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
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
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

    @Test("a blocked coordinated read is cancelled at the access deadline")
    func coordinationDeadlineCancelsBlockedRead() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let root = Self.useFakeContainer()
        let dir = root.appendingPathComponent("Library/books/abc")
        try Files.createDirectory(dir)
        let path = dir.appendingPathComponent("meta.json")
        try Files.write("content", to: path)

        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)
        // A private queue, not `DispatchQueue.global()`: under a full
        // `swift test` run the default pool can sit idle past a
        // one-second wait, which is what failed this case in CI.
        let blockerQueue = DispatchQueue(
            label: "io.github.nathanstefanik.margins.filestore-blocker",
            qos: .userInitiated
        )
        blockerQueue.async {
            let blocker = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            blocker.coordinate(
                writingItemAt: URL(fileURLWithPath: path),
                options: .forReplacing,
                error: &coordinationError
            ) { _ in
                blockerStarted.signal()
                _ = releaseBlocker.wait(timeout: .now() + 10)
            }
            blockerFinished.signal()
        }
        try #require(blockerStarted.wait(timeout: .now() + 10) == .success)

        FileStore.accessDeadline = 0.5
        defer {
            FileStore.accessDeadline = 8
            releaseBlocker.signal()
            _ = blockerFinished.wait(timeout: .now() + 2)
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try FileStore.readData(path)
            Issue.record("expected the blocked read to be cancelled")
        } catch let error as CoreError {
            if case .io = error {
                // Expected: `checked` maps coordinator cancellation to I/O.
            } else {
                Issue.record("expected CoreError.io, got \(error)")
            }
        } catch {
            Issue.record("expected CoreError.io, got \(error)")
        }
        #expect(start.duration(to: clock.now) < .seconds(2))
    }
}
