import Foundation

// The remote side of library sync (docs/architecture.md): the iOS library
// is local-first in `Documents/Library`, and the iCloud container keeps a
// replica that `LibrarySync` drives through this protocol. `ICloudRemote`
// is the production adapter over the ubiquity container;
// `DirectoryRemote` is a plain-directory stand-in for tests and the DEBUG
// simulator fixture.

/// One file as the remote sees it. `modified` is the remote's own clock —
/// compared for freshness, never trusted to match a local mtime.
public struct RemoteEntry: Equatable, Sendable {
    public var size: Int64
    public var modified: Date
    /// Content is on this device and current — readable now.
    public var isDownloaded: Bool
    /// Finished uploading — safe to drop this device's copy.
    public var isUploaded: Bool

    public init(size: Int64, modified: Date, isDownloaded: Bool, isUploaded: Bool) {
        self.size = size
        self.modified = modified
        self.isDownloaded = isDownloaded
        self.isUploaded = isUploaded
    }
}

/// A file-by-file remote tree sync can list, read, write, and delete.
/// Paths are "/"-separated, relative to the remote root.
public protocol SyncRemote: Sendable {
    /// Account identity; a change discards the sync base. nil = unknown.
    func identity() async -> String?
    /// Every regular file under the remote root, keyed by "/"-separated
    /// path relative to the root. Any path component starting with "."
    /// is excluded.
    func snapshot() async throws -> [String: RemoteEntry]
    /// Filesystem confirmation independent of `snapshot`: the logical
    /// file or a `.name.icloud` placeholder exists.
    func exists(_ path: String) async -> Bool
    /// Copies current content to `destination` (replacing). Only called
    /// when `snapshot` reported the entry downloaded.
    func download(_ path: String, to destination: URL) async throws
    /// Writes `source` at `path` (creating parents), replacing
    /// atomically; returns the entry as it now stands.
    func upload(from source: URL, to path: String) async throws -> RemoteEntry
    func remove(_ path: String) async throws
    /// Asks the remote to fetch `path`'s content to this device.
    func requestDownload(_ path: String) async
    /// Drops this device's copy of `path`; the remote keeps its content.
    func evictLocalCopy(_ path: String) async
    /// Removes now-empty directories from `path`'s parent upward,
    /// stopping below the root.
    func pruneEmptyParents(of path: String) async
    /// Calls `onChange` when the remote tree changes (no-op by default).
    func startMonitoring(_ onChange: @escaping @Sendable () -> Void) async
    /// Whether `stored` — a base64 string `identity()` returned earlier —
    /// names the same account this remote serves now. Serialized bytes
    /// can drift across launches, so adapters with a real token compare
    /// it semantically rather than by string.
    func identityMatches(_ stored: String) async -> Bool
}

extension SyncRemote {
    public func startMonitoring(_ onChange: @escaping @Sendable () -> Void) async {}
    public func identityMatches(_ stored: String) async -> Bool {
        await identity() == stored
    }
}

/// A plain directory behind the `SyncRemote` interface — every entry
/// reports downloaded and uploaded, and downloads/uploads are copies.
/// Tests and the DEBUG simulator fixture sync against this.
public final class DirectoryRemote: SyncRemote {
    private let root: URL
    /// Symlink-resolved root for path math: temp directories on macOS sit
    /// under `/var`, which resolves to `/private/var`, and enumerated
    /// children report either spelling depending on the API.
    private let rootPath: String

    public init(root: URL) {
        self.root = root
        self.rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func identity() async -> String? {
        "directory:" + root.path
    }

    public func snapshot() async throws -> [String: RemoteEntry] {
        var entries: [String: RemoteEntry] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return entries }
        for case let url as URL in enumerator.allObjects {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let path = String(resolved.dropFirst(rootPath.count + 1))
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            entries[path] = RemoteEntry(
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast,
                isDownloaded: true,
                isUploaded: true
            )
        }
        return entries
    }

    public func exists(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    public func download(_ path: String, to destination: URL) async throws {
        let manager = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: url(for: path), to: temp)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temp, to: destination)
    }

    public func upload(from source: URL, to path: String) async throws -> RemoteEntry {
        let manager = FileManager.default
        let destination = url(for: path)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".margins-upload-\(UUID().uuidString)")
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: temp)
        try manager.copyItem(at: source, to: temp)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try manager.moveItem(at: temp, to: destination)
        }
        let values = try destination.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        return RemoteEntry(
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            isDownloaded: true,
            isUploaded: true
        )
    }

    public func remove(_ path: String) async throws {
        try FileManager.default.removeItem(at: url(for: path))
    }

    public func requestDownload(_ path: String) async {}

    public func evictLocalCopy(_ path: String) async {}

    public func pruneEmptyParents(of path: String) async {
        let manager = FileManager.default
        var directory = url(for: path).deletingLastPathComponent()
        while directory.path.count > 1 {
            let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != rootPath, resolved.hasPrefix(rootPath + "/") else { break }
            guard (try? manager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
            else { break }
            try? manager.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    private func url(for path: String) -> URL {
        root.appendingPathComponent(path)
    }
}
