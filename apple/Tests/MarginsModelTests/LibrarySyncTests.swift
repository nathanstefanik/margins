import Foundation
import MarginsCore
import MarginsModel
import Testing

/// The sync engine (docs/architecture.md): local-first, newest-wins file
/// by file, a manifest as the sync base, a delete brake against bogus
/// empty listings, and no local appearance of a book before its EPUB.
/// `FakeRemote` plays the iCloud failure modes — files present but not
/// downloaded, and files the listing omits while `exists` still sees
/// them — over a real directory.
@Suite("LibrarySync")
struct LibrarySyncTests {
    // MARK: Doubles

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func with<T>(_ body: (inout Value) -> T) -> T {
            lock.withLock { body(&value) }
        }
    }

    private struct FakeState {
        var notDownloaded: Set<String> = []
        var unlisted: Set<String> = []
        var uploaded = true
        var identity: String? = "fake-remote"
        var requestedDownloads: [String] = []
        var evicted: [String] = []
        var uploads: [String] = []
        var removes: [String] = []
        var downloads: [String] = []
        var snapshotCalls = 0
        var onSnapshot: (@Sendable () async throws -> Void)?
        var identityMatchesResult: Bool?
    }

    private final class FakeRemote: SyncRemote, @unchecked Sendable {
        let real: DirectoryRemote
        private let state = Locked(FakeState())

        init(root: URL) {
            real = DirectoryRemote(root: root)
        }

        func with<T>(_ body: (inout FakeState) -> T) -> T {
            state.with(body)
        }

        func identity() async -> String? {
            state.with { $0.identity }
        }

        func identityMatches(_ stored: String) async -> Bool {
            if let result = state.with({ $0.identityMatchesResult }) {
                return result
            }
            return await identity() == stored
        }

        func snapshot() async throws -> [String: RemoteEntry] {
            let hook = state.with { current -> (@Sendable () async throws -> Void)? in
                defer { current.onSnapshot = nil }
                return current.onSnapshot
            }
            try await hook?()
            var entries = try await real.snapshot()
            state.with { $0.snapshotCalls += 1 }
            let knobs = state.with { ($0.unlisted, $0.notDownloaded, $0.uploaded) }
            for path in knobs.0 { entries[path] = nil }
            for (path, var entry) in entries {
                entry.isDownloaded = !knobs.1.contains(path)
                entry.isUploaded = knobs.2
                entries[path] = entry
            }
            return entries
        }

        func exists(_ path: String) async -> Bool {
            await real.exists(path)
        }

        func download(_ path: String, to destination: URL) async throws {
            state.with { $0.downloads.append(path) }
            if state.with({ $0.notDownloaded.contains(path) }) {
                struct NotDownloaded: Error, LocalizedError {
                    var errorDescription: String? { "remote content not downloaded" }
                }
                throw NotDownloaded()
            }
            try await real.download(path, to: destination)
        }

        func upload(from source: URL, to path: String) async throws -> RemoteEntry {
            state.with { $0.uploads.append(path) }
            var entry = try await real.upload(from: source, to: path)
            entry.isUploaded = state.with { $0.uploaded }
            return entry
        }

        func remove(_ path: String) async throws {
            try await real.remove(path)
            state.with { $0.removes.append(path) }
        }

        func requestDownload(_ path: String) async {
            state.with { $0.requestedDownloads.append(path) }
        }

        func evictLocalCopy(_ path: String) async {
            state.with { $0.evicted.append(path) }
        }

        func pruneEmptyParents(of path: String) async {
            await real.pruneEmptyParents(of: path)
        }
    }

    /// A one-shot rendezvous for the coalescing test: `hold` parks the
    /// first snapshot until `open`, `waitUntilEntered` observes it.
    private final class SnapshotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var released = false
        private var onEntered: CheckedContinuation<Void, Never>?
        private var onRelease: CheckedContinuation<Void, Never>?

        func hold() async {
            lock.withLock {
                entered = true
                onEntered?.resume()
                onEntered = nil
            }
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if released { continuation.resume() } else { onRelease = continuation }
                }
            }
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if entered { continuation.resume() } else { onEntered = continuation }
                }
            }
        }

        func open() {
            lock.withLock {
                released = true
                onRelease?.resume()
                onRelease = nil
            }
        }
    }

    // MARK: Harness

    private struct Harness {
        let root: URL
        let localRoot: URL
        let remoteRoot: URL
        let stateDirectory: URL
        let remote: FakeRemote
        let sync: LibrarySync

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("margins-sync-\(UUID().uuidString)", isDirectory: true)
            localRoot = root.appendingPathComponent("local/Library", isDirectory: true)
            remoteRoot = root.appendingPathComponent("remote/Library", isDirectory: true)
            stateDirectory = root.appendingPathComponent("state", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: localRoot, withIntermediateDirectories: true)
            try manager.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
            remote = FakeRemote(root: remoteRoot)
            sync = LibrarySync(
                localRoot: localRoot, remote: remote, stateDirectory: stateDirectory)
        }

        @discardableResult
        func write(_ content: String, at path: String, in dir: URL, modified: Date? = nil)
            throws -> URL
        {
            let url = dir.appendingPathComponent(path)
            let manager = FileManager.default
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            if let modified {
                try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url
        }

        @discardableResult
        func writeLocal(_ content: String, at path: String, modified: Date? = nil) throws -> URL {
            try write(content, at: path, in: localRoot, modified: modified)
        }

        @discardableResult
        func writeRemote(_ content: String, at path: String, modified: Date? = nil) throws -> URL {
            try write(content, at: path, in: remoteRoot, modified: modified)
        }

        /// A minimal book tree: meta, source, and one chapter note.
        func writeBook(_ id: String, in dir: URL? = nil) throws {
            let dir = dir ?? localRoot
            try write("meta \(id)", at: "books/\(id)/meta.json", in: dir)
            try write("epub \(id)", at: "books/\(id)/source.epub", in: dir)
            try write("note \(id)", at: "books/\(id)/notes/chapters/001.md", in: dir)
        }

        func localText(_ path: String) throws -> String {
            try String(contentsOf: localRoot.appendingPathComponent(path), encoding: .utf8)
        }

        func remoteText(_ path: String) throws -> String {
            try String(contentsOf: remoteRoot.appendingPathComponent(path), encoding: .utf8)
        }

        func localExists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: localRoot.appendingPathComponent(path).path)
        }

        func remoteExists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent(path).path)
        }

        func setLocalMtime(_ path: String, _ date: Date) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: localRoot.appendingPathComponent(path).path)
        }

        func setRemoteMtime(_ path: String, _ date: Date) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: remoteRoot.appendingPathComponent(path).path)
        }

        /// The stashed copy of `path`, if the pass wrote one.
        func stashedText(_ path: String) throws -> String? {
            let overwritten = stateDirectory.appendingPathComponent("overwritten")
            let manager = FileManager.default
            guard let folders = try? manager.contentsOfDirectory(atPath: overwritten.path)
            else { return nil }
            for folder in folders {
                let candidate = overwritten.appendingPathComponent("\(folder)/\(path)")
                if manager.fileExists(atPath: candidate.path) {
                    return try String(contentsOf: candidate, encoding: .utf8)
                }
            }
            return nil
        }
    }

    private static func report(_ sync: LibrarySync) async throws -> SyncReport {
        try #require(await sync.sync(), "sync ran no pass")
    }

    // MARK: First sync

    @Test("a fresh local library pushes to an empty remote, meta.json last")
    func freshPush() async throws {
        let harness = try Harness()
        try harness.writeBook("b1")
        let fixture = try #require(try fixtureEpubs().first)
        let epubPath = harness.localRoot.appendingPathComponent("books/b1/source.epub").path
        try FileManager.default.removeItem(atPath: epubPath)
        try FileManager.default.copyItem(atPath: fixture, toPath: epubPath)

        let report = try await Self.report(harness.sync)
        #expect(report.pushed == 3)
        #expect(report.pulled == 0)
        #expect(harness.remote.with { $0.uploads.last } == "books/b1/meta.json")
        #expect(harness.remoteExists("books/b1/meta.json"))
        #expect(harness.remoteExists("books/b1/source.epub"))

        // Steady state: nothing left to do.
        let second = try await Self.report(harness.sync)
        #expect(second == SyncReport())
    }

    @Test("a fresh pull lands the whole remote book, meta.json last")
    func freshPull() async throws {
        let harness = try Harness()
        try harness.writeBook("b1", in: harness.remoteRoot)

        let report = try await Self.report(harness.sync)
        #expect(report.pulled == 3)
        #expect(report.pushed == 0)
        #expect(harness.remote.with { $0.downloads.last } == "books/b1/meta.json")
        #expect(try harness.localText("books/b1/meta.json") == "meta b1")

        let second = try await Self.report(harness.sync)
        #expect(second == SyncReport())
    }

    @Test("a book's meta.json never lands before its EPUB")
    func metaWaitsForEpub() async throws {
        let harness = try Harness()
        try harness.writeBook("b1", in: harness.remoteRoot)
        harness.remote.with { $0.notDownloaded = ["books/b1/source.epub"] }

        let report = try await Self.report(harness.sync)
        #expect(report.pulled == 1)  // just the note file
        #expect(report.waitingForDownload >= 1)
        #expect(harness.remote.with { $0.requestedDownloads } == ["books/b1/source.epub"])
        #expect(!harness.localExists("books/b1/meta.json"))
        #expect(!harness.localExists("books/b1/source.epub"))

        // The EPUB lands: the next pass pulls it and the held-back meta.
        harness.remote.with { $0.notDownloaded = [] }
        let second = try await Self.report(harness.sync)
        #expect(second.pulled == 2)
        #expect(harness.localExists("books/b1/source.epub"))
        #expect(harness.localExists("books/b1/meta.json"))
    }

    // MARK: Edits

    @Test("a local edit pushes, a remote edit pulls")
    func editsPropagate() async throws {
        let harness = try Harness()
        try harness.writeLocal("v1", at: "books/b1/position.json")
        try harness.writeLocal("v1", at: "notebooks/nb.md")
        _ = try await Self.report(harness.sync)

        try harness.writeLocal("v2", at: "books/b1/position.json")
        let pushed = try await Self.report(harness.sync)
        #expect(pushed.pushed == 1)
        #expect(try harness.remoteText("books/b1/position.json") == "v2")

        try harness.writeRemote("v3", at: "notebooks/nb.md", modified: Date() + 3600)
        let pulled = try await Self.report(harness.sync)
        #expect(pulled.pulled == 1)
        #expect(try harness.localText("notebooks/nb.md") == "v3")
    }

    @Test("newest wins each way, and the loser is stashed")
    func conflictNewestWins() async throws {
        let harness = try Harness()
        try harness.writeLocal("base", at: "notebooks/nb.md")
        try harness.writeLocal("base", at: "notebooks/other.md")
        _ = try await Self.report(harness.sync)

        // Local newer: push, and the remote's losing bytes are stashed.
        try harness.writeLocal("local wins", at: "notebooks/nb.md", modified: Date() + 7200)
        try harness.writeRemote("remote loses", at: "notebooks/nb.md", modified: Date() + 3600)
        var report = try await Self.report(harness.sync)
        #expect(report.pushed == 1)
        #expect(try harness.remoteText("notebooks/nb.md") == "local wins")
        #expect(try harness.stashedText("notebooks/nb.md") == "remote loses")

        // Remote newer: pull, and the local file's losing bytes are stashed.
        try harness.writeLocal("local loses", at: "notebooks/other.md", modified: Date() + 3600)
        try harness.writeRemote("remote wins", at: "notebooks/other.md", modified: Date() + 7200)
        report = try await Self.report(harness.sync)
        #expect(report.pulled == 1)
        #expect(try harness.localText("notebooks/other.md") == "remote wins")
        #expect(try harness.stashedText("notebooks/other.md") == "local loses")
    }

    // MARK: Deletes

    @Test("deletes propagate both ways, and an edit beats a delete")
    func deletesAndEditBeatsDelete() async throws {
        let harness = try Harness()
        try harness.writeLocal("a", at: "notebooks/a.md")
        try harness.writeLocal("b", at: "notebooks/b.md")
        try harness.writeLocal("c", at: "notebooks/c.md")
        try harness.writeLocal("d", at: "notebooks/d.md")
        _ = try await Self.report(harness.sync)

        // Local delete → remote delete.
        try FileManager.default.removeItem(
            at: harness.localRoot.appendingPathComponent("notebooks/a.md"))
        var report = try await Self.report(harness.sync)
        #expect(report.deletedRemote == 1)
        #expect(!harness.remoteExists("notebooks/a.md"))
        #expect(harness.remote.with { $0.removes } == ["notebooks/a.md"])

        // Remote delete → local delete.
        try FileManager.default.removeItem(
            at: harness.remoteRoot.appendingPathComponent("notebooks/b.md"))
        report = try await Self.report(harness.sync)
        #expect(report.deletedLocal == 1)
        #expect(!harness.localExists("notebooks/b.md"))

        // Local delete + remote edit → the edit pulls back.
        try FileManager.default.removeItem(
            at: harness.localRoot.appendingPathComponent("notebooks/c.md"))
        try harness.writeRemote("c edited", at: "notebooks/c.md", modified: Date() + 3600)
        report = try await Self.report(harness.sync)
        #expect(report.pulled == 1)
        #expect(try harness.localText("notebooks/c.md") == "c edited")

        // Remote delete + local edit → the edit pushes back.
        try FileManager.default.removeItem(
            at: harness.remoteRoot.appendingPathComponent("notebooks/d.md"))
        try harness.writeLocal("d edited", at: "notebooks/d.md")
        report = try await Self.report(harness.sync)
        #expect(report.pushed == 1)
        #expect(try harness.remoteText("notebooks/d.md") == "d edited")
    }

    // MARK: Listing lag and identity

    @Test("an unlisted-but-present remote file is never treated as deleted")
    func listingLag() async throws {
        let harness = try Harness()
        try harness.writeLocal("synced", at: "notebooks/nb.md")
        _ = try await Self.report(harness.sync)

        // The file has a base entry but drops out of the snapshot.
        harness.remote.with { $0.unlisted = ["notebooks/nb.md"] }
        var report = try await Self.report(harness.sync)
        #expect(report.deletedLocal == 0)
        #expect(harness.localExists("notebooks/nb.md"))

        // A base-less local file whose remote twin is unlisted is not
        // pushed either.
        try harness.writeLocal("new", at: "notebooks/new.md")
        try harness.writeRemote("other", at: "notebooks/new.md")
        harness.remote.with { $0.unlisted = ["notebooks/nb.md", "notebooks/new.md"] }
        report = try await Self.report(harness.sync)
        #expect(report.pushed == 0)
        #expect(!harness.remote.with { $0.uploads }.contains("notebooks/new.md"))
    }

    @Test("an identity change discards the base instead of deleting")
    func identityChange() async throws {
        let harness = try Harness()
        try harness.writeLocal("a", at: "notebooks/a.md")
        _ = try await Self.report(harness.sync)

        // The remote loses a file and the account changes: with the base
        // discarded nothing is deletable, and the gap pushes back.
        try FileManager.default.removeItem(
            at: harness.remoteRoot.appendingPathComponent("notebooks/a.md"))
        harness.remote.with { $0.identity = "another-account" }

        let report = try await Self.report(harness.sync)
        #expect(report.deletedLocal == 0)
        #expect(report.deletedRemote == 0)
        #expect(harness.localExists("notebooks/a.md"))
        #expect(harness.remoteExists("notebooks/a.md"))
    }

    @Test("the remote decides identity equality, not the stored string")
    func identitySemanticMatch() async throws {
        let harness = try Harness()
        try harness.writeLocal("a", at: "notebooks/a.md")
        _ = try await Self.report(harness.sync)

        // The stored string no longer matches today's serialization, but
        // the remote still says same account: the base survives, so the
        // remote-side delete still propagates locally.
        harness.remote.with {
            $0.identity = "rotated-serialization"
            $0.identityMatchesResult = true
        }
        try FileManager.default.removeItem(
            at: harness.remoteRoot.appendingPathComponent("notebooks/a.md"))

        let report = try await Self.report(harness.sync)
        #expect(report.deletedLocal == 1)
        #expect(!harness.localExists("notebooks/a.md"))
    }

    // MARK: The brake

    @Test("a wiped remote cannot wipe the local library")
    func brakeStopsMassDelete() async throws {
        let harness = try Harness()
        for id in ["b1", "b2", "b3", "b4"] {
            try harness.writeBook(id)
        }
        _ = try await Self.report(harness.sync)

        // The remote claims everything is gone.
        try FileManager.default.removeItem(at: harness.remoteRoot)
        let remote = FakeRemote(
            root: harness.root.appendingPathComponent("remote/Library", isDirectory: true))
        let sync = LibrarySync(
            localRoot: harness.localRoot, remote: remote,
            stateDirectory: harness.stateDirectory)

        let report = try await Self.report(sync)
        #expect(report.brakeEngaged)
        #expect(report.deletedLocal == 0)
        #expect(harness.localExists("books/b1/meta.json"))
        // The "deletes" became re-uploads.
        #expect(remote.with { $0.uploads }.count == 12)
        #expect(harness.remoteExists("books/b2/meta.json"))
    }

    // MARK: Adoption and steady state

    @Test("identical content on both sides is adopted, never transferred")
    func adoptSameContent() async throws {
        let harness = try Harness()
        try harness.writeLocal("same", at: "notebooks/nb.md")
        try harness.writeRemote("same", at: "notebooks/nb.md")
        try harness.writeLocal("epub", at: "books/b1/source.epub")
        try harness.writeRemote("epub", at: "books/b1/source.epub")
        // The EPUB isn't downloaded — immutable files adopt anyway.
        harness.remote.with { $0.notDownloaded = ["books/b1/source.epub"] }

        let report = try await Self.report(harness.sync)
        #expect(report.pushed == 0)
        #expect(report.pulled == 0)
        #expect(harness.remote.with { $0.requestedDownloads }.isEmpty)
        #expect(!harness.remote.with { $0.downloads }.contains("books/b1/source.epub"))

        let second = try await Self.report(harness.sync)
        #expect(second == SyncReport())
    }

    @Test("an mtime bump with identical bytes transfers nothing")
    func mtimeBumpNoTransfer() async throws {
        let harness = try Harness()
        try harness.writeLocal("same", at: "notebooks/nb.md")
        _ = try await Self.report(harness.sync)

        try harness.setLocalMtime("notebooks/nb.md", Date() + 3600)
        var report = try await Self.report(harness.sync)
        #expect(report == SyncReport())

        try harness.setRemoteMtime("notebooks/nb.md", Date() + 7200)
        report = try await Self.report(harness.sync)
        #expect(report == SyncReport())
    }

    @Test("hidden files and the root index.json never transfer")
    func scopeExclusions() async throws {
        let harness = try Harness()
        try harness.writeLocal("local catalog", at: "index.json")
        try harness.writeLocal("junk", at: ".DS_Store")
        try harness.writeLocal("junk", at: "books/b1/.hidden")
        try harness.writeLocal("real", at: "books/b1/meta.json")
        try harness.writeRemote("remote catalog", at: "index.json")
        try harness.writeRemote("secret", at: ".hidden-file")

        let report = try await Self.report(harness.sync)
        #expect(report.pushed == 1)
        #expect(report.pulled == 0)
        #expect(harness.remote.with { $0.uploads } == ["books/b1/meta.json"])
        // Neither side's index.json moved.
        #expect(try harness.remoteText("index.json") == "remote catalog")
        #expect(try harness.localText("index.json") == "local catalog")
        #expect(!harness.localExists(".hidden-file"))
    }

    @Test("an uploaded source.epub is evicted locally, and only it")
    func evictUploadedEpub() async throws {
        let harness = try Harness()
        try harness.writeBook("b1")

        _ = try await Self.report(harness.sync)
        // The next pass sees the uploaded EPUB in the snapshot and drops
        // the local copy — nothing else qualifies.
        _ = try await Self.report(harness.sync)
        #expect(harness.remote.with { $0.evicted } == ["books/b1/source.epub"])

        // Not yet uploaded: nothing to evict.
        harness.remote.with { $0.uploaded = false }
        _ = try await Self.report(harness.sync)
        #expect(harness.remote.with { $0.evicted } == ["books/b1/source.epub"])
    }

    // MARK: Report sets

    @Test("pulls report the touched books and notebooks")
    func reportChangeSets() async throws {
        let harness = try Harness()
        try harness.writeRemote("meta", at: "books/b1/meta.json")
        try harness.writeRemote("note", at: "books/b1/notes/chapters/001.md")
        try harness.writeRemote("position", at: "books/b2/position.json")
        try harness.writeRemote("nb", at: "notebooks/nb.md")

        let report = try await Self.report(harness.sync)
        #expect(report.pulled == 4)
        #expect(report.changedBookIds == ["b1", "b2"])
        #expect(report.notesChangedBookIds == ["b1"])
        #expect(report.notebooksChanged)
    }

    // MARK: Mirror seeding

    @Test("seedFromMirror moves missing EPUBs and never overwrites")
    func seedFromMirror() async throws {
        let harness = try Harness()
        let fixture = try #require(try fixtureEpubs().first)
        let bookId = try Library.contentID(ofFile: fixture)
        let mirror = harness.root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: fixture, toPath: mirror.appendingPathComponent("\(bookId).epub").path)
        // One the local library already has: must not be overwritten.
        try FileManager.default.copyItem(
            atPath: fixture, toPath: mirror.appendingPathComponent("present.epub").path)
        try harness.writeLocal("existing", at: "books/present/source.epub")

        let moved = try LibrarySync.seedFromMirror(
            mirrorDirectory: mirror, localRoot: harness.localRoot)
        #expect(moved == 1)
        #expect(
            try Data(
                contentsOf: harness.localRoot.appendingPathComponent(
                    "books/\(bookId)/source.epub")) == Data(contentsOf: URL(fileURLWithPath: fixture)))
        #expect(try harness.localText("books/present/source.epub") == "existing")
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
    }

    // MARK: Coalescing

    @Test("a sync during a running pass coalesces into a follow-up")
    func coalescing() async throws {
        let harness = try Harness()
        try harness.writeLocal("a", at: "books/b1/meta.json")

        let gate = SnapshotGate()
        harness.remote.with { $0.onSnapshot = { await gate.hold() } }

        async let first = harness.sync.sync()
        await gate.waitUntilEntered()

        // The running pass holds the actor; this call only asks for more.
        let second = await harness.sync.sync()
        #expect(second == nil)

        gate.open()
        let merged = try #require(await first)
        // The follow-up pass ran: two snapshots, one file pushed once.
        #expect(harness.remote.with { $0.snapshotCalls } == 2)
        #expect(merged.pushed == 1)
    }
}
