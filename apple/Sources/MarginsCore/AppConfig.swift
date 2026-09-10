import Foundation

/// The app's data directory and the library root inside it, plus the
/// `config.json` that remembers a user-chosen root (docs/storage.md).
///
/// Resolution order for the library root: `MARGINS_LIBRARY_ROOT`, then the
/// saved path, then `{dataDir}/library`. The environment variable wins so a
/// developer or a test can point a build at a scratch tree without
/// disturbing the saved configuration.
public struct AppConfig: Sendable {
    /// `{dataDir}/config.json`, the only thing stored outside the library.
    struct Stored: Codable, Sendable, Equatable {
        var libraryRoot: String?

        enum CodingKeys: String, CodingKey {
            case libraryRoot = "library_root"
        }

        init(libraryRoot: String? = nil) {
            self.libraryRoot = libraryRoot
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            libraryRoot = try container.decodeIfPresent(String.self, forKey: .libraryRoot)
        }
    }

    public private(set) var dataDir: String
    public private(set) var libraryRoot: String
    private var stored: Stored

    /// - Parameter dataDir: explicit data directory, or `nil` to resolve
    ///   `MARGINS_DATA_DIR` / the platform default.
    public init(dataDir explicit: String? = nil) throws {
        let dataDir = explicit ?? Self.resolveDataDir()
        do {
            try FileManager.default.createDirectory(
                atPath: dataDir, withIntermediateDirectories: true
            )
        } catch {
            throw CoreError.config("io error: \(error.localizedDescription)")
        }

        let configPath = (dataDir as NSString).appendingPathComponent("config.json")
        var stored = Stored()
        if FileManager.default.fileExists(atPath: configPath) {
            do {
                let raw = try Data(contentsOf: URL(fileURLWithPath: configPath))
                stored = try MarginsJSON.decode(Stored.self, from: raw)
            } catch {
                throw CoreError.config("json error: \(error.localizedDescription)")
            }
        }

        self.dataDir = dataDir
        self.stored = stored
        self.libraryRoot = Self.resolveLibraryRoot(dataDir: dataDir, configured: stored.libraryRoot)
    }

    /// Points the library at `path`, creating it and saving the choice. A
    /// failed save leaves the config untouched rather than half-applied.
    public mutating func setLibraryRoot(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
        } catch {
            throw CoreError.config("io error: \(error.localizedDescription)")
        }

        let previous = stored.libraryRoot
        stored.libraryRoot = path
        do {
            try persist()
        } catch {
            stored.libraryRoot = previous
            throw error
        }
        libraryRoot = path
    }

    private func persist() throws {
        let configPath = (dataDir as NSString).appendingPathComponent("config.json")
        do {
            try MarginsJSON.encode(stored).write(to: URL(fileURLWithPath: configPath))
        } catch {
            throw CoreError.config("io error: \(error.localizedDescription)")
        }
    }

    // MARK: Resolution

    static func resolveDataDir() -> String {
        if let fromEnvironment = environmentPath("MARGINS_DATA_DIR") { return fromEnvironment }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base?.path ?? ".").appendingPathComponent("margins")
    }

    static func resolveLibraryRoot(dataDir: String, configured: String?) -> String {
        environmentPath("MARGINS_LIBRARY_ROOT")
            ?? configured
            ?? dataDir.appendingPathComponent("library")
    }

    /// An environment path, treating empty as unset the way the legacy core did.
    private static func environmentPath(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension String {
    /// Path join that keeps `NSString`'s separator handling without the cast
    /// noise at every call site.
    func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}
