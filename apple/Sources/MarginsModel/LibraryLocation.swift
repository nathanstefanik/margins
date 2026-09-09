import Foundation

/// Resolves and guards the iOS library root. The library lives in the app's
/// iCloud Documents ubiquity container (visible in Files, pointable from
/// the Mac via `MARGINS_LIBRARY_ROOT`); when no container is available —
/// no paid team, not signed into iCloud — it falls back to local
/// `Documents/Library` **at runtime**, never at build time.
///
/// Everything the Rust core must not know about iCloud lives here:
/// materializing evicted placeholders before the core reads a path, and
/// conflict detection for note files (last-writer-wins governs content;
/// conflicts are surfaced, never silently discarded).
public struct LibraryLocation: Sendable {
    public enum Source: Equatable, Sendable {
        /// The ubiquity container's `Documents/Library` directory.
        case iCloudDocuments(path: String)
        /// Local `Documents/Library` — the fallback, with the reason
        /// surfaced by the UI.
        case localDocuments(path: String)
    }

    public struct MaterializationError: LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }

        static func timeout(_ path: String) -> Self {
            Self(message: "iCloud download timed out for \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    /// Resolves the ubiquity container, or nil when unavailable. Injectable
    /// for tests; the default asks FileManager (returns nil without an
    /// iCloud entitlement/account).
    private let containerProvider: @Sendable () -> URL?
    private let documentsProvider: @Sendable () -> URL
    /// Download-poll iterations (100ms each); injectable so tests bound
    /// the wait instead of running the production timeout.
    private let downloadPollLimit: Int

    public init(
        containerProvider: @escaping @Sendable () -> URL? = {
            FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
        },
        documentsProvider: @escaping @Sendable () -> URL = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        },
        downloadPollLimit: Int = 100
    ) {
        self.containerProvider = containerProvider
        self.documentsProvider = documentsProvider
        self.downloadPollLimit = downloadPollLimit
    }

    /// Resolves the library root. The container's directory is created on
    /// first launch if the container exists but the folder is not yet
    /// materialized (normal first-launch state).
    public func resolve() -> Source {
        if let container = containerProvider() {
            let root = container.appendingPathComponent("Library", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return .iCloudDocuments(path: root.path)
        }
        let root = documentsProvider().appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return .localDocuments(path: root.path)
    }

    /// Ensures the file at `path` is fully downloaded before the core reads
    /// it. Local files (and already-current iCloud items) pass through;
    /// evicted placeholders start downloading and the call waits, bounded.
    public func materializedPath(for path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: path)
        // An evicted ubiquitous item exists only as a `.name.icloud`
        // placeholder beside the logical path, so `fileExists` at the
        // logical path reports missing — exactly the case this method
        // exists for; it must not early-return there.
        let evicted = !exists && Self.hasEvictedPlaceholder(for: url)
        guard exists || evicted else { return path }

        let isUbiquitous = evicted
            || ((try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?
                .isUbiquitousItem ?? false)
        guard isUbiquitous else { return path }

        if !evicted,
           (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
               .ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current
        {
            return path
        }
        // `startDownloadingUbiquitousItem` accepts the logical URL of an
        // evicted placeholder. A throw means "no such item at all", which
        // passes through like any other missing file (the core owns the
        // not-found error).
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            return path
        }
        for _ in 0..<downloadPollLimit {
            if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current
            {
                return path
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MaterializationError.timeout(path)
    }

    /// True when the file at `url` exists only as an evicted iCloud
    /// placeholder (a `.<name>.icloud` sibling beside the logical path).
    /// Pure over the filesystem so tests can reproduce eviction with
    /// fixture files.
    public static func hasEvictedPlaceholder(for url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// Copies a security-scoped picked file (document picker) into a
    /// temporary staging path under `NSFileCoordinator` coordination, so
    /// the core can read it after the picker's scope is released.
    public func stagedCopy(of pickedURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(pickedURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)

        final class Box: @unchecked Sendable {
            var error: Error?
        }
        let box = Box()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            readingItemAt: pickedURL,
            options: [.forUploading],
            error: &coordinationError
        ) { source in
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                box.error = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let copyError = box.error {
            throw copyError
        }
        return destination
    }

    /// File names of unresolved iCloud conflict versions for the item at
    /// `path` (empty when the file is local or has no conflicts). The
    /// core's last-writer-wins content stands; callers surface the names
    /// so the user knows a conflict existed.
    public static func unresolvedConflictFileNames(at path: String) -> [String] {
        NSFileVersion
            .unresolvedConflictVersionsOfItem(at: URL(fileURLWithPath: path))?
            .compactMap { $0.localizedName } ?? []
    }
}
