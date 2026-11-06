import Foundation

/// The small pieces of iCloud/Documents file plumbing the library still
/// needs. The library itself is local-first — the sync engine owns the
/// iCloud replica; this type only stages security-scoped imports and
/// nudges iCloud downloads (used for pulled files that haven't landed).
public struct LibraryLocation: Sendable {
    public init() {}

    /// Asks iCloud to download `path`. Errors are ignored: a non-ubiquitous
    /// path is a no-op, and a daemon refusal is not the caller's to surface.
    public static func requestDownload(_ path: String) {
        try? FileManager.default.startDownloadingUbiquitousItem(
            at: URL(fileURLWithPath: path))
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
}
