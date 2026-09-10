import Foundation

// Coordinated document I/O for the core's own files: `meta.json`,
// `position.json`, `notes/**`, and `notes/_index.json`
// (docs/apple-only-plan.md Phase 2 step 5).
//
// When the path lives inside the ubiquity container — the iOS library root
// (LibraryLocation resolves it to `Documents/Library`) — every read and
// write is wrapped in `NSFileCoordinator` so it serializes against iCloud's
// sync engine: reads of evicted placeholders wait for content, writes
// register cleanly with sync, and renames and removals are announced.
// Everywhere else (macOS, the local iOS fallback, the app-support config)
// the same calls are a plain passthrough to `Files`.
//
// Deliberately NOT coordinated, keeping the plan's scope to the core's
// documents: `source.epub` reads (the reader's scheme handler calls from
// WebKit threads, and the app materializes first with its own bounded
// progress UI), cover images, `README.md`, and the search engine's
// revalidation reads (a derived cache that tolerates a dataless file by
// dropping it until it reappears).
//
// An evicted ubiquitous item exists only as a `.<name>.icloud` placeholder
// beside the logical path, where `fileExists` reports missing. `exists` and
// `isFile` here count the placeholder as existing, so a not-yet-downloaded
// index or note is never mistaken for a missing one and, say, a compile
// cannot silently report zero notes.

enum FileStore {
    private static let resolver = ContainerResolver()

    /// Resolves the ubiquity container's Documents directory once per
    /// process and guards the (test-only) override. All decisions flow
    /// through one lock; the expensive `FileManager` lookup happens at most
    /// once per resolution.
    private final class ContainerResolver: @unchecked Sendable {
        private let lock = NSLock()
        private var provider: @Sendable () -> URL? = ContainerResolver.default
        /// `nil` = not resolved yet; resolved value may itself be nil
        /// (no container — no entitlement, not signed in, or plain macOS).
        private var cachedRoot: String??

        static let `default`: @Sendable () -> URL? = {
            FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
        }

        func root() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = cachedRoot { return cached }
            let resolved = provider()?.path
            cachedRoot = .some(resolved)
            return resolved
        }

        func overrideProvider(_ replacement: (@Sendable () -> URL?)?) {
            lock.lock()
            defer { lock.unlock() }
            provider = replacement ?? Self.default
            cachedRoot = nil
        }
    }

    /// Test seam: overrides the container resolver and drops the cache.
    /// Passing `nil` restores the default. Paths outside the override stay
    /// on the passthrough, so suites using their own temp directories are
    /// unaffected.
    static func overrideContainerProvider(_ replacement: (@Sendable () -> URL?)?) {
        resolver.overrideProvider(replacement)
    }

    /// True when `path` is inside the container, i.e. handled by
    /// `NSFileCoordinator`.
    static func isCoordinated(_ path: String) -> Bool {
        guard let root = resolver.root() else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    /// True when the item exists — counting an evicted iCloud placeholder.
    static func exists(_ path: String) -> Bool {
        if Files.exists(path) { return true }
        return isCoordinated(path) && hasEvictedPlaceholder(path)
    }

    /// True when the item is a file — counting an evicted iCloud placeholder.
    static func isFile(_ path: String) -> Bool {
        if Files.isFile(path) { return true }
        return isCoordinated(path) && hasEvictedPlaceholder(path)
    }

    /// Directory entries as full paths, with evicted iCloud placeholders
    /// reported under their logical names — a note that only exists in the
    /// cloud is still enumerated, counted, and clearable. Outside the
    /// container a `.<name>.icloud` file is just a plain file and is
    /// reported as-is.
    static func contents(ofDirectory path: String) throws -> [String] {
        let coordinated = isCoordinated(path)
        return try Files.contents(ofDirectory: path).map { entry in
            let name = (entry as NSString).lastPathComponent
            if coordinated, name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 {
                return (path as NSString)
                    .appendingPathComponent(String(name.dropFirst().dropLast(7)))
            }
            return entry
        }
    }

    static func read(_ path: String) throws -> String {
        let data = try readData(path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.io("io error: could not read \(path): not UTF-8")
        }
        return text
    }

    static func readData(_ path: String) throws -> Data {
        guard isCoordinated(path) else { return try Files.readData(path) }
        let box = Box()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            readingItemAt: URL(fileURLWithPath: path),
            error: &coordinationError
        ) { url in
            do {
                box.data = try Data(contentsOf: url)
            } catch {
                box.error = error
            }
        }
        guard let data = try checked(box, operation: "read", path: path, coordinationError) else {
            throw CoreError.io("io error: could not read \(path)")
        }
        return data
    }

    static func write(_ text: String, to path: String) throws {
        try writeData(Data(text.utf8), to: path)
    }

    static func writeData(_ data: Data, to path: String) throws {
        guard isCoordinated(path) else { return try Files.writeData(data, to: path) }
        let box = Box()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: URL(fileURLWithPath: path),
            error: &coordinationError
        ) { url in
            do {
                // Atomic inside the accessor, so sync only ever sees a
                // complete file.
                try data.write(to: url, options: .atomic)
            } catch {
                box.error = error
            }
        }
        _ = try checked(box, operation: "write", path: path, coordinationError)
    }

    /// Moves the item, announcing both ends to the coordinator (the
    /// documented pattern for moves: read the source, write the destination).
    static func rename(_ path: String, to destination: String) throws {
        guard isCoordinated(path) || isCoordinated(destination) else {
            return try Files.rename(path, to: destination)
        }
        let box = Box()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            readingItemAt: URL(fileURLWithPath: path),
            error: &coordinationError
        ) { source in
            var nestedError: NSError?
            coordinator.coordinate(
                writingItemAt: URL(fileURLWithPath: destination),
                options: .forReplacing,
                error: &nestedError
            ) { dest in
                do {
                    try FileManager.default.moveItem(atPath: source.path, toPath: dest.path)
                } catch {
                    box.error = error
                }
            }
            if let nestedError, box.error == nil {
                box.error = nestedError
            }
        }
        _ = try checked(box, operation: "move", path: path, coordinationError)
    }

    /// Removes the item. An evicted placeholder has no logical file to
    /// remove, so the placeholder itself is deleted instead — a cleared
    /// note must not survive its own eviction.
    static func remove(_ path: String) throws {
        guard isCoordinated(path) else { return try Files.remove(path) }
        let box = Box()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: URL(fileURLWithPath: path),
            options: .forDeleting,
            error: &coordinationError
        ) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if hasEvictedPlaceholder(url.path) {
                    let placeholder = Self.placeholderPath(url.path)
                    try? FileManager.default.removeItem(atPath: placeholder)
                } else {
                    box.error = error
                }
            }
        }
        _ = try checked(box, operation: "remove", path: path, coordinationError)
    }

    // MARK: Plumbing

    /// The accessor result, mirroring `LibraryLocation`'s coordination
    /// pattern: `NSFileCoordinator`'s accessor is synchronous but not
    /// Sendable-checked, so results cross through a box.
    private final class Box: @unchecked Sendable {
        var data: Data?
        var error: Error?
    }

    private static func checked(
        _ box: Box, operation: String, path: String, _ coordinationError: NSError?
    ) throws -> Data? {
        if let coordinationError {
            throw CoreError.io(
                "io error: could not \(operation) \(path): \(coordinationError.localizedDescription)"
            )
        }
        if let accessorError = box.error {
            throw CoreError.io(
                "io error: could not \(operation) \(path): \(accessorError.localizedDescription)"
            )
        }
        return box.data
    }

    /// `.<name>.icloud` sibling of the logical path — the evicted
    /// placeholder's on-disk name.
    private static func placeholderPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
            .path
    }

    private static func hasEvictedPlaceholder(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: placeholderPath(path))
    }
}
