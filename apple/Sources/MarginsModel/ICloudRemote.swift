import Foundation
import MarginsCore

// The production `SyncRemote`: the iCloud Documents ubiquity container's
// `Library/` directory. Snapshotting is an `NSMetadataQuery` (it must live
// on the main run loop but never blocks the main actor — gathering is
// awaited); file movement goes through `NSFileCoordinator` on detached
// tasks with a 30 s cancel watchdog, mirroring `FileStore`.
//
// This adapter stays deliberately thin — it cannot be exercised in tests
// (no ubiquity container off-device); the sync engine's logic is tested
// against `DirectoryRemote`.

public final class ICloudRemote: SyncRemote, @unchecked Sendable {
    private let root: URL
    /// Symlink-resolved, standardized root path. iCloud reports item URLs
    /// under `/private/var/...` while callers hand us `/var/...` — all
    /// comparisons go through the resolved spelling.
    private let rootPath: String
    private let monitor = MonitorBox()

    /// The long-lived monitoring query and its observer — the class stays
    /// immutable otherwise, so Sendable is unchecked on their account.
    private final class MonitorBox {
        var query: NSMetadataQuery?
        var observer: NSObjectProtocol?
    }

    public init(root: URL) {
        self.root = root
        self.rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Identity and listing

    /// The token archived to a base64 string for the manifest. The token
    /// need not adopt NSSecureCoding; fall back to the plain archiver
    /// rather than reporting no account.
    static func archive(_ token: NSObject) -> String? {
        let data =
            (try? NSKeyedArchiver.archivedData(
                withRootObject: token, requiringSecureCoding: true))
            ?? (try? NSKeyedArchiver.archivedData(
                withRootObject: token, requiringSecureCoding: false))
        return data?.base64EncodedString()
    }

    /// Whether `stored` — a base64 string `archive(_:)` produced — names
    /// the same account as `current`. Serialized token bytes can differ
    /// launch to launch, so equality is decided on the unarchived token;
    /// the root object lives under `NSKeyedArchiveRootObjectKey`.
    static func token(_ stored: String, matches current: NSObject) -> Bool {
        guard let data = Data(base64Encoded: stored),
            let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return false }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        guard
            let storedToken = unarchiver.decodeObject(
                forKey: NSKeyedArchiveRootObjectKey) as? NSObject
        else { return false }
        return storedToken.isEqual(current)
    }

    public func identity() async -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken as? NSObject
        else { return nil }
        return Self.archive(token)
    }

    public func identityMatches(_ stored: String) async -> Bool {
        guard let token = FileManager.default.ubiquityIdentityToken as? NSObject
        else { return false }
        return Self.token(stored, matches: token)
    }

    public func snapshot() async throws -> [String: RemoteEntry] {
        try await gatherSnapshot()
    }

    /// Raw items → scope-filtered entries. Runs wherever the caller is —
    /// inside the gather it runs on the main queue before the query
    /// stops, while `results` is still valid.
    private func remoteEntries(from items: [NSMetadataItem]) -> [String: RemoteEntry] {
        var entries: [String: RemoteEntry] = [:]
        for item in items {
            guard let rawURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else {
                continue
            }
            // Folders are not files; the query lists both.
            if (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String)
                == "public.folder" || rawURL.hasDirectoryPath
            {
                continue
            }
            let resolved = rawURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let path = String(resolved.dropFirst(rootPath.count + 1))
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                continue
            }
            let size =
                (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?
                .int64Value ?? 0
            let modified =
                (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)
                ?? .distantPast
            let downloaded =
                (item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey)
                    as? String) == NSMetadataUbiquitousItemDownloadingStatusCurrent
            let uploaded =
                (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? NSNumber)?
                .boolValue ?? false
            entries[path] = RemoteEntry(
                size: size, modified: modified,
                isDownloaded: downloaded, isUploaded: uploaded)
        }
        return entries
    }

    /// The gather's shared state — the query (not Sendable), its
    /// observer, and the continuation — checked Sendable off because
    /// every access happens on the main queue or the main actor.
    private final class QueryBox: @unchecked Sendable {
        let query = NSMetadataQuery()
        var observer: NSObjectProtocol?
        var continuation: CheckedContinuation<[String: RemoteEntry], any Error>?
        var resumed = false

        /// Called only on the main queue / main actor, so `resumed` needs
        /// no lock: first caller wins, the rest are dropped.
        func finish(_ result: Result<[String: RemoteEntry], any Error>) {
            guard !resumed else { return }
            resumed = true
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            query.stop()
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// Runs one `NSMetadataQuery` to its initial gather and returns the
    /// mapped results. Created, started, and read on the main actor (the
    /// query needs the main run loop); the wait is a continuation, so
    /// the main actor is never blocked. Throws after 30 s without a
    /// gather.
    @MainActor
    private func gatherSnapshot() async throws -> [String: RemoteEntry] {
        let box = QueryBox()
        box.query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        box.query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        return try await withCheckedThrowingContinuation { continuation in
            box.continuation = continuation
            box.observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: box.query,
                queue: .main
            ) { _ in
                box.query.disableUpdates()
                let items = box.query.results as? [NSMetadataItem] ?? []
                box.finish(.success(self.remoteEntries(from: items)))
            }
            box.query.start()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                box.finish(
                    .failure(CoreError.io("io error: iCloud snapshot timed out")))
            }
        }
    }

    public func startMonitoring(_ onChange: @escaping @Sendable () -> Void) async {
        await MainActor.run {
            guard monitor.query == nil else { return }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
            monitor.observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { _ in
                onChange()
            }
            query.start()
            monitor.query = query
        }
    }

    // MARK: Existence and transfer

    public func exists(_ path: String) async -> Bool {
        let url = url(for: path)
        let manager = FileManager.default
        return manager.fileExists(atPath: url.path)
            || manager.fileExists(atPath: placeholder(of: url).path)
    }

    public func download(_ path: String, to destination: URL) async throws {
        let source = url(for: path)
        try await coordinated { coordinator in
            var coordinationError: NSError?
            var accessorError: (any Error)?
            coordinator.coordinate(
                readingItemAt: source,
                options: .withoutChanges,
                error: &coordinationError
            ) { accessed in
                do {
                    let manager = FileManager.default
                    let temp = destination.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(destination.lastPathComponent)-\(UUID().uuidString)")
                    try manager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try manager.copyItem(at: accessed, to: temp)
                    if manager.fileExists(atPath: destination.path) {
                        try manager.removeItem(at: destination)
                    }
                    try manager.moveItem(at: temp, to: destination)
                } catch {
                    accessorError = error
                }
            }
            if let error = coordinationError ?? accessorError {
                throw error
            }
        }
    }

    public func upload(from source: URL, to path: String) async throws -> RemoteEntry {
        let destination = url(for: path)
        try await coordinated { coordinator in
            var coordinationError: NSError?
            var accessorError: (any Error)?
            coordinator.coordinate(
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { accessed in
                do {
                    let manager = FileManager.default
                    try manager.createDirectory(
                        at: accessed.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    let temp = accessed.deletingLastPathComponent()
                        .appendingPathComponent(".margins-upload-\(UUID().uuidString)")
                    try? manager.removeItem(at: temp)
                    try manager.copyItem(at: source, to: temp)
                    if manager.fileExists(atPath: accessed.path) {
                        // replaceItemAt keeps the ubiquitous item's
                        // identity — a move makes iCloud see delete+add.
                        _ = try manager.replaceItemAt(accessed, withItemAt: temp)
                    } else {
                        try manager.moveItem(at: temp, to: accessed)
                    }
                } catch {
                    accessorError = error
                }
            }
            if let error = coordinationError ?? accessorError {
                throw error
            }
        }
        let values = try destination.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        return RemoteEntry(
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            isDownloaded: true,
            isUploaded: false
        )
    }

    public func remove(_ path: String) async throws {
        let target = url(for: path)
        try await coordinated { coordinator in
            var coordinationError: NSError?
            var accessorError: (any Error)?
            coordinator.coordinate(
                writingItemAt: target,
                options: .forDeleting,
                error: &coordinationError
            ) { accessed in
                do {
                    try FileManager.default.removeItem(at: accessed)
                } catch {
                    // The logical file is gone but its `.icloud` stub may
                    // remain — deleting the item means deleting that too.
                    let stub = self.placeholder(of: accessed)
                    if FileManager.default.fileExists(atPath: stub.path) {
                        try? FileManager.default.removeItem(at: stub)
                    } else {
                        accessorError = error
                    }
                }
            }
            if let error = coordinationError ?? accessorError {
                throw error
            }
        }
    }

    public func requestDownload(_ path: String) async {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url(for: path))
    }

    public func evictLocalCopy(_ path: String) async {
        try? FileManager.default.evictUbiquitousItem(at: url(for: path))
    }

    public func pruneEmptyParents(of path: String) async {
        let manager = FileManager.default
        var directory = url(for: path).deletingLastPathComponent()
        while directory.path.count > 1 {
            let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != rootPath, resolved.hasPrefix(rootPath + "/") else { break }
            guard (try? manager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
            else { break }
            let current = directory
            try? await coordinated { coordinator in
                var coordinationError: NSError?
                coordinator.coordinate(
                    writingItemAt: current,
                    options: .forDeleting,
                    error: &coordinationError
                ) { accessed in
                    try? FileManager.default.removeItem(at: accessed)
                }
            }
            guard !manager.fileExists(atPath: directory.path) else { break }
            directory = directory.deletingLastPathComponent()
        }
    }

    // MARK: Plumbing

    private func url(for path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// The `.<name>.icloud` sibling of a logical file URL.
    private func placeholder(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// Runs a coordinated file operation on a detached task with a 30 s
    /// cancellation watchdog, like `FileStore.cancellationWorkItem` — a
    /// wedged daemon must not hang a sync pass.
    private func coordinated(
        _ body: @escaping @Sendable (NSFileCoordinator) throws -> Void
    ) async throws {
        try await Task.detached {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let watchdog = DispatchWorkItem { coordinator.cancel() }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + 30, execute: watchdog)
            defer { watchdog.cancel() }
            try body(coordinator)
        }.value
    }
}
