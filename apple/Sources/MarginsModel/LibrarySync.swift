import CryptoKit
import Foundation

// Local-first library sync (docs/architecture.md): the iOS library lives
// on the phone and the remote — iCloud in production, a plain directory
// in tests — is a replica this engine keeps in step. Conflict policy is
// newest-wins, file by file; a losing local edit is stashed privately
// under `overwritten/` and a losing remote one is stashed the same way
// (downloaded first) so nothing is silently discarded.
//
// Correctness rests on the manifest: the stamps both sides carried at the
// last successful sync (`base`). A file is changed exactly when its
// content differs from base — an mtime touch alone is refreshed, never
// transferred; content the remote merely hasn't downloaded yet is
// requested and waited on, never pulled blind.

/// What one `sync()` run — possibly several coalesced passes — did.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var deletedLocal = 0
    public var deletedRemote = 0
    /// Remote files needed here that aren't downloaded yet (download
    /// requested). Also counts pulled `meta.json` files gated on their
    /// book's EPUB arriving first.
    public var waitingForDownload = 0
    /// "relative/path: message", at most 20; "snapshot: …" when the
    /// listing itself failed.
    public var failures: [String] = []
    /// Books with any local file pulled or deleted this run.
    public var changedBookIds: Set<String> = []
    /// Books whose `notes/**` changed locally — the app reconciles their
    /// index.
    public var notesChangedBookIds: Set<String> = []
    /// Anything under `notebooks/` pulled or deleted locally.
    public var notebooksChanged = false
    public var brakeEngaged = false

    public init() {}

    mutating func merge(_ other: SyncReport) {
        pushed += other.pushed
        pulled += other.pulled
        deletedLocal += other.deletedLocal
        deletedRemote += other.deletedRemote
        waitingForDownload += other.waitingForDownload
        failures.append(contentsOf: other.failures)
        if failures.count > 20 { failures = Array(failures.prefix(20)) }
        changedBookIds.formUnion(other.changedBookIds)
        notesChangedBookIds.formUnion(other.notesChangedBookIds)
        notebooksChanged = notebooksChanged || other.notebooksChanged
        brakeEngaged = brakeEngaged || other.brakeEngaged
    }
}

/// The persisted sync base: what both sides agreed on at the last pass.
struct SyncManifest: Codable {
    var version = 1
    var identity: String?
    var files: [String: BaseEntry] = [:]
}

/// The content hash both sides had at last sync, plus the stamps that let
/// a pass detect change without re-hashing.
struct BaseEntry: Codable, Equatable {
    /// SHA-256 hex of the content both sides had at last sync.
    var hash: String
    var localSize: Int64
    /// Exact mtime, seconds since 1970 — the local side's clock is ours.
    var localModified: Double
    var remoteSize: Int64
    /// Remote mtimes are another clock's and arrive at lower precision;
    /// compared with a 1 s tolerance.
    var remoteModified: Double
}

public actor LibrarySync {
    private let localRoot: URL
    private let localRootPath: String
    private let remote: any SyncRemote
    private let stateDirectory: URL
    private var running = false
    private var followUp = false

    public init(localRoot: URL, remote: any SyncRemote, stateDirectory: URL) {
        self.localRoot = localRoot
        self.localRootPath = localRoot.resolvingSymlinksInPath().standardizedFileURL.path
        self.remote = remote
        self.stateDirectory = stateDirectory
    }

    /// Runs a pass. If one is already running, requests a follow-up pass
    /// from it and returns nil; the running call loops until no follow-up
    /// is pending and returns the merged report.
    public func sync() async -> SyncReport? {
        if running {
            followUp = true
            return nil
        }
        running = true
        var merged = SyncReport()
        repeat {
            followUp = false
            merged.merge(await runPass())
        } while followUp
        running = false
        return merged
    }

    /// One-time migration: moves `<mirror>/<id>.epub` into
    /// `<localRoot>/books/<id>/source.epub` where that file is missing
    /// (never overwrites), then removes the mirror directory. Returns the
    /// moved count.
    @discardableResult
    public static func seedFromMirror(mirrorDirectory: URL, localRoot: URL) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: mirrorDirectory.path) else { return 0 }
        var moved = 0
        for name in try manager.contentsOfDirectory(atPath: mirrorDirectory.path)
        where name.hasSuffix(".epub") {
            let destination =
                localRoot
                .appendingPathComponent("books/\(name.dropLast(5))/source.epub")
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: mirrorDirectory.appendingPathComponent(name), to: destination)
            moved += 1
        }
        try? manager.removeItem(at: mirrorDirectory)
        return moved
    }

    // MARK: The pass

    private struct LocalStamp: Equatable {
        var size: Int64
        var modified: Double
    }

    private enum Action {
        case push
        case pull
        case deleteLocal
        case deleteRemote
    }

    private struct Plan {
        var action: Action
        /// Stash the local file before a pull replaces it.
        var stashLocal = false
        /// Stash a download of the remote file before a push replaces it.
        var stashRemote = false
    }

    private var manifestURL: URL { stateDirectory.appendingPathComponent("manifest.json") }
    private var tmpDirectory: URL { stateDirectory.appendingPathComponent("tmp") }
    private var overwrittenDirectory: URL {
        stateDirectory.appendingPathComponent("overwritten")
    }

    /// Per-pass caches, reset at each pass start: local content hashes by
    /// path, and downloads staged under `tmp/` so a pull reuses what
    /// classification fetched.
    private var passLocalHashes: [String: String] = [:]
    private var passStaged: [String: URL] = [:]

    private func localHash(_ path: String) throws -> String {
        if let hash = passLocalHashes[path] { return hash }
        let hash = try Self.sha256Hex(of: localRoot.appendingPathComponent(path))
        passLocalHashes[path] = hash
        return hash
    }

    private func stageDownload(_ path: String) async throws -> URL {
        if let url = passStaged[path], FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let url = tmpDirectory.appendingPathComponent(UUID().uuidString)
        try await remote.download(path, to: url)
        passStaged[path] = url
        return url
    }

    private func runPass() async -> SyncReport {
        var report = SyncReport()
        let manager = FileManager.default
        passLocalHashes = [:]
        passStaged = [:]
        try? manager.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
        clearTmp()
        pruneStash()

        var manifest = loadManifest()
        let currentIdentity = await remote.identity()
        if let stored = manifest.identity, currentIdentity != nil,
            await !remote.identityMatches(stored)
        {
            // A different account's remote shares nothing with this base;
            // a fresh base also means no remote deletions are provable.
            manifest.files = [:]
            manifest.identity = currentIdentity
        } else if manifest.identity == nil {
            manifest.identity = currentIdentity
        }

        let remoteFiles: [String: RemoteEntry]
        do {
            remoteFiles = try await remote.snapshot()
        } catch {
            record(&report, "snapshot: \(error.localizedDescription)")
            return report
        }

        let localFiles = walkLocal()

        var paths = Set(localFiles.keys)
        paths.formUnion(remoteFiles.keys)
        paths.formUnion(manifest.files.keys)
        let scoped = paths.filter(Self.inScope).sorted()

        var plans: [String: Plan] = [:]

        // MARK: Classify

        for path in scoped {
            let local = localFiles[path]
            let entry = remoteFiles[path]
            var base = manifest.files[path]
            let immutable = Self.isImmutableEpub(path)

            var localChanged = false
            if let local {
                if let base {
                    if !immutable,
                        local.size != base.localSize || local.modified != base.localModified
                    {
                        do {
                            if try localHash(path) == base.hash {
                                // Stamp moved, content didn't — refresh.
                                var base = base
                                base.localSize = local.size
                                base.localModified = local.modified
                                manifest.files[path] = base
                            } else {
                                localChanged = true
                            }
                        } catch {
                            record(&report, "\(path): \(error.localizedDescription)")
                            continue
                        }
                    }
                } else {
                    localChanged = true
                }
            }

            var remoteChanged = false
            if let entry {
                if let base {
                    let stampMatches =
                        entry.size == base.remoteSize
                        && abs(entry.modified.timeIntervalSince1970 - base.remoteModified) < 1
                    if !immutable, !stampMatches {
                        if entry.size == base.remoteSize && entry.isDownloaded {
                            do {
                                let hash = try Self.sha256Hex(of: await stageDownload(path))
                                if hash == base.hash {
                                    var base = base
                                    base.remoteSize = entry.size
                                    base.remoteModified = entry.modified.timeIntervalSince1970
                                    manifest.files[path] = base
                                } else {
                                    remoteChanged = true
                                }
                            } catch {
                                record(&report, "\(path): \(error.localizedDescription)")
                                continue
                            }
                        } else {
                            // Sizes differ — content must — or the content
                            // isn't here to check; either counts as changed.
                            remoteChanged = true
                        }
                    }
                } else {
                    remoteChanged = true
                }
            }
            base = manifest.files[path]

            switch (local != nil, entry != nil, base != nil) {
            case (true, false, false):
                // Local only, never synced: the remote may merely lag the
                // listing — confirm absence before overwriting it.
                if await remote.exists(path) { continue }
                plans[path] = Plan(action: .push)
            case (false, true, false):
                if entry!.isDownloaded {
                    plans[path] = Plan(action: .pull)
                } else {
                    await remote.requestDownload(path)
                    report.waitingForDownload += 1
                }
            case (true, true, false):
                if immutable {
                    do {
                        manifest.files[path] = BaseEntry(
                            hash: try localHash(path),
                            localSize: local!.size, localModified: local!.modified,
                            remoteSize: entry!.size,
                            remoteModified: entry!.modified.timeIntervalSince1970)
                    } catch {
                        record(&report, "\(path): \(error.localizedDescription)")
                    }
                } else if entry!.isDownloaded {
                    do {
                        let remoteHash = try Self.sha256Hex(of: await stageDownload(path))
                        if remoteHash == (try localHash(path)) {
                            manifest.files[path] = BaseEntry(
                                hash: remoteHash,
                                localSize: local!.size, localModified: local!.modified,
                                remoteSize: entry!.size,
                                remoteModified: entry!.modified.timeIntervalSince1970)
                        } else {
                            plans[path] = await newestWins(
                                path: path, local: local!, entry: entry!, report: &report)
                        }
                    } catch {
                        record(&report, "\(path): \(error.localizedDescription)")
                    }
                } else {
                    // Can't tell equal from divergent without the bytes.
                    await remote.requestDownload(path)
                    report.waitingForDownload += 1
                }
            case (true, true, true):
                switch (localChanged, remoteChanged) {
                case (false, false):
                    break
                case (true, false):
                    plans[path] = Plan(action: .push)
                case (false, true):
                    if entry!.isDownloaded {
                        plans[path] = Plan(action: .pull)
                    } else {
                        await remote.requestDownload(path)
                        report.waitingForDownload += 1
                    }
                case (true, true):
                    plans[path] = await newestWins(
                        path: path, local: local!, entry: entry!, report: &report)
                }
            case (true, false, true):
                // Remote may be deleted, or just missing from this listing.
                if await remote.exists(path) { continue }
                plans[path] = Plan(action: localChanged ? .push : .deleteLocal)
            case (false, true, true):
                if remoteChanged {
                    // An edit beats a delete: pull it back.
                    if entry!.isDownloaded {
                        plans[path] = Plan(action: .pull)
                    } else {
                        await remote.requestDownload(path)
                        report.waitingForDownload += 1
                    }
                } else {
                    plans[path] = Plan(action: .deleteRemote)
                }
            case (false, false, true):
                manifest.files[path] = nil
            case (false, false, false):
                break
            }
        }

        // MARK: The brake
        //
        // Wiping a whole side because the other claims it's empty is how
        // sync engines lose libraries: if one pass would delete most of
        // the books it knows, the claim is almost certainly a listing
        // failure, so deletions become restorations instead.
        let booksInBase = Set(
            manifest.files.keys.compactMap(Self.bookId(ofMetaPath:))
        ).count
        var deleteLocal = plans.compactMap { $0.value.action == .deleteLocal ? $0.key : nil }
        var deleteRemote = plans.compactMap { $0.value.action == .deleteRemote ? $0.key : nil }

        let deletingLocalBooks = Set(deleteLocal.compactMap(Self.bookId(ofMetaPath:))).count
        if deletingLocalBooks >= 3 && deletingLocalBooks * 2 > booksInBase {
            report.brakeEngaged = true
            for path in deleteLocal { plans[path] = Plan(action: .push) }
            deleteLocal = []
        }
        let deletingRemoteBooks = Set(deleteRemote.compactMap(Self.bookId(ofMetaPath:))).count
        if deletingRemoteBooks >= 3 && deletingRemoteBooks * 2 > booksInBase {
            report.brakeEngaged = true
            for path in deleteRemote {
                if remoteFiles[path]?.isDownloaded == true {
                    plans[path] = Plan(action: .pull)
                } else {
                    plans[path] = nil
                    await remote.requestDownload(path)
                    report.waitingForDownload += 1
                }
            }
            deleteRemote = []
        }

        // MARK: Execute

        var transfers = 0
        func checkpoint() {
            transfers += 1
            if transfers % 25 == 0 { saveManifest(manifest) }
        }
        // meta.json last for transfers in: a book must not appear before
        // its content; meta.json first for deletes: it must disappear
        // before its content does.
        let pushes = plans.compactMap { $0.value.action == .push ? $0.key : nil }
            .sorted { (Self.isBookMeta($0) ? 1 : 0, $0) < (Self.isBookMeta($1) ? 1 : 0, $1) }
        let pulls = plans.compactMap { $0.value.action == .pull ? $0.key : nil }
            .sorted { (Self.isBookMeta($0) ? 1 : 0, $0) < (Self.isBookMeta($1) ? 1 : 0, $1) }
        deleteLocal.sort { (Self.isBookMeta($0) ? 0 : 1, $0) < (Self.isBookMeta($1) ? 0 : 1, $1) }
        deleteRemote.sort { (Self.isBookMeta($0) ? 0 : 1, $0) < (Self.isBookMeta($1) ? 0 : 1, $1) }

        for path in pushes {
            do {
                if plans[path]?.stashRemote == true {
                    try await stashRemoteCopy(path)
                }
                let url = localRoot.appendingPathComponent(path)
                guard try Self.stat(url) == localFiles[path] else { continue }
                let entry = try await remote.upload(from: url, to: path)
                manifest.files[path] = BaseEntry(
                    hash: try localHash(path),
                    localSize: localFiles[path]!.size,
                    localModified: localFiles[path]!.modified,
                    remoteSize: entry.size,
                    remoteModified: entry.modified.timeIntervalSince1970)
                report.pushed += 1
                checkpoint()
            } catch {
                record(&report, "\(path): \(error.localizedDescription)")
            }
        }

        for path in pulls {
            // A book never appears locally without its EPUB: pull
            // meta.json only once the local source.epub exists, or when
            // the remote has none to wait for.
            if Self.isBookMeta(path), let bookId = Self.bookId(ofMetaPath: path) {
                let epubPath = "books/\(bookId)/source.epub"
                let localEpub = localRoot.appendingPathComponent(epubPath)
                if remoteFiles[epubPath] != nil,
                    !manager.fileExists(atPath: localEpub.path)
                {
                    report.waitingForDownload += 1
                    continue
                }
            }
            do {
                if plans[path]?.stashLocal == true {
                    try stashLocalCopy(path)
                }
                let stagedURL = try await stageDownload(path)
                let hash = try Self.sha256Hex(of: stagedURL)
                let url = localRoot.appendingPathComponent(path)
                // Re-stat: an edit or a new file since classification wins.
                guard try Self.statIfPresent(url) == localFiles[path] else {
                    try? manager.removeItem(at: stagedURL)
                    continue
                }
                try manager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: url.path) {
                    try manager.removeItem(at: url)
                }
                try manager.moveItem(at: stagedURL, to: url)
                let placed = try Self.stat(url)
                let entry = remoteFiles[path]!
                manifest.files[path] = BaseEntry(
                    hash: hash,
                    localSize: placed.size, localModified: placed.modified,
                    remoteSize: entry.size,
                    remoteModified: entry.modified.timeIntervalSince1970)
                report.pulled += 1
                noteLocalChange(path, into: &report)
                checkpoint()
            } catch {
                record(&report, "\(path): \(error.localizedDescription)")
            }
        }

        for path in deleteLocal {
            do {
                let url = localRoot.appendingPathComponent(path)
                guard try Self.statIfPresent(url) == localFiles[path] else { continue }
                try manager.removeItem(at: url)
                manifest.files[path] = nil
                report.deletedLocal += 1
                noteLocalChange(path, into: &report)
                checkpoint()
            } catch {
                record(&report, "\(path): \(error.localizedDescription)")
            }
        }
        for path in deleteLocal {
            pruneLocalParents(of: path)
        }

        for path in deleteRemote {
            do {
                try await remote.remove(path)
                manifest.files[path] = nil
                report.deletedRemote += 1
                checkpoint()
                await remote.pruneEmptyParents(of: path)
            } catch {
                record(&report, "\(path): \(error.localizedDescription)")
            }
        }

        // Uploaded EPUBs don't need to sit on this device twice.
        for (path, _) in manifest.files where Self.isImmutableEpub(path) {
            guard let entry = remoteFiles[path], entry.isDownloaded, entry.isUploaded,
                manager.fileExists(atPath: localRoot.appendingPathComponent(path).path)
            else { continue }
            await remote.evictLocalCopy(path)
        }

        saveManifest(manifest)
        return report
    }

    /// Newest-wins for a file changed on both sides: the newer mtime wins
    /// the transfer, and the loser's bytes are stashed first. A remote
    /// win needs the content downloaded — if it isn't, we wait.
    private func newestWins(
        path: String, local: LocalStamp, entry: RemoteEntry, report: inout SyncReport
    ) async -> Plan? {
        if local.modified > entry.modified.timeIntervalSince1970 {
            return Plan(action: .push, stashRemote: entry.isDownloaded)
        }
        guard entry.isDownloaded else {
            await remote.requestDownload(path)
            report.waitingForDownload += 1
            return nil
        }
        return Plan(action: .pull, stashLocal: true)
    }

    /// A pulled or locally deleted file that touches a book or the
    /// notebooks dir updates the report's change sets.
    private func noteLocalChange(_ path: String, into report: inout SyncReport) {
        let components = path.split(separator: "/")
        if components.first == "notebooks" {
            report.notebooksChanged = true
        }
        guard components.count >= 3, components[0] == "books" else { return }
        let bookId = String(components[1])
        report.changedBookIds.insert(bookId)
        if components[2] == "notes" {
            report.notesChangedBookIds.insert(bookId)
        }
    }

    private func record(_ report: inout SyncReport, _ failure: String) {
        guard report.failures.count < 20 else { return }
        report.failures.append(failure)
    }

    // MARK: Files

    /// Regular files under the local root, stamped — the same scope rules
    /// the remote applies.
    private func walkLocal() -> [String: LocalStamp] {
        var files: [String: LocalStamp] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: localRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return files }
        for case let url as URL in enumerator.allObjects {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(localRootPath + "/") else { continue }
            let path = String(resolved.dropFirst(localRootPath.count + 1))
            guard Self.inScope(path),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                let stamp = try? Self.stat(url)
            else { continue }
            files[path] = stamp
        }
        return files
    }

    /// In scope: every regular file except paths with a "."-prefixed
    /// component and the root-level `index.json` (the catalog each device
    /// regenerates).
    private static func inScope(_ path: String) -> Bool {
        if path == "index.json" { return false }
        return !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// `books/<id>/source.epub` — the content-hash-named original never
    /// changes, so it never transfers once adopted.
    private static func isImmutableEpub(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count == 3 && components[0] == "books" && components[2] == "source.epub"
    }

    /// `books/<id>/meta.json`.
    private static func isBookMeta(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count == 3 && components[0] == "books" && components[2] == "meta.json"
    }

    /// The `<id>` of a `books/<id>/meta.json` path.
    private static func bookId(ofMetaPath path: String) -> String? {
        guard isBookMeta(path) else { return nil }
        return String(path.split(separator: "/")[1])
    }

    private static func stat(_ url: URL) throws -> LocalStamp {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        return LocalStamp(
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    private static func statIfPresent(_ url: URL) throws -> LocalStamp? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try stat(url)
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: State

    private func loadManifest() -> SyncManifest {
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(SyncManifest.self, from: data)
        else { return SyncManifest() }
        return manifest
    }

    private func saveManifest(_ manifest: SyncManifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func clearTmp() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: tmpDirectory.path)) ?? [] {
            try? manager.removeItem(at: tmpDirectory.appendingPathComponent(name))
        }
    }

    /// One stash folder per pass: `overwritten/<stamp>/<relpath>`, created
    /// on first use.
    private var stashFolder: String?

    private func stashURL(for path: String) -> URL {
        if stashFolder == nil {
            stashFolder = Self.stampFormatter.string(from: Date())
        }
        return
            overwrittenDirectory
            .appendingPathComponent(stashFolder!).appendingPathComponent(path)
    }

    private func stashLocalCopy(_ path: String) throws {
        let manager = FileManager.default
        let destination = stashURL(for: path)
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: localRoot.appendingPathComponent(path), to: destination)
    }

    /// The losing remote version of a conflict, kept privately — a push
    /// replaces it remotely, so it is copied into the stash first,
    /// reusing the staged download when classification fetched one.
    private func stashRemoteCopy(_ path: String) async throws {
        let destination = stashURL(for: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let staged = passStaged[path],
            FileManager.default.fileExists(atPath: staged.path)
        {
            try FileManager.default.copyItem(at: staged, to: destination)
        } else {
            try await remote.download(path, to: destination)
        }
    }

    /// Stash folders age out after 30 days — they're a safety net, not an
    /// archive.
    private func pruneStash() {
        stashFolder = nil
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: overwrittenDirectory.path)
        else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for name in names {
            guard let date = Self.stampFormatter.date(from: name), date < cutoff else { continue }
            try? manager.removeItem(at: overwrittenDirectory.appendingPathComponent(name))
        }
    }

    /// The `overwritten/<stamp>` folder name format.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    /// Empty parent directories a local delete left behind, below root.
    private func pruneLocalParents(of path: String) {
        let manager = FileManager.default
        var directory = localRoot.appendingPathComponent(path).deletingLastPathComponent()
        while directory.path.count > 1 {
            let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != localRootPath, resolved.hasPrefix(localRootPath + "/")
            else { break }
            guard (try? manager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
            else { break }
            try? manager.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }
}
