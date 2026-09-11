import Foundation

/// The app's data directory and the library root inside it, plus the
/// `config.json` that remembers a user-chosen root and the club spoiler
/// toggle (docs/storage.md).
///
/// Resolution order for the library root: `MARGINS_LIBRARY_ROOT`, then the
/// saved path, then `{dataDir}/library`. The environment variable wins so a
/// developer or a test can point a build at a scratch tree without
/// disturbing the saved configuration.
public struct AppConfig: Sendable {
    /// `{dataDir}/config.json`, the only thing stored outside the library.
    struct Stored: Codable, Sendable, Equatable {
        var libraryRoot: String?
        /// Absent means the default (`true`); an explicit `false` survives.
        var clubSpoilerProtection: Bool?
        /// Stable local club member identity, generated on first use.
        var clubMemberId: String?
        var clubDisplayName: String?

        enum CodingKeys: String, CodingKey {
            case libraryRoot = "library_root"
            case clubSpoilerProtection = "club_spoiler_protection"
            case clubMemberId = "club_member_id"
            case clubDisplayName = "club_display_name"
        }

        init(
            libraryRoot: String? = nil,
            clubSpoilerProtection: Bool? = nil,
            clubMemberId: String? = nil,
            clubDisplayName: String? = nil
        ) {
            self.libraryRoot = libraryRoot
            self.clubSpoilerProtection = clubSpoilerProtection
            self.clubMemberId = clubMemberId
            self.clubDisplayName = clubDisplayName
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            libraryRoot = try container.decodeIfPresent(String.self, forKey: .libraryRoot)
            clubSpoilerProtection = try container.decodeIfPresent(
                Bool.self, forKey: .clubSpoilerProtection
            )
            clubMemberId = try container.decodeIfPresent(String.self, forKey: .clubMemberId)
            clubDisplayName = try container.decodeIfPresent(String.self, forKey: .clubDisplayName)
        }
    }

    public private(set) var dataDir: String
    public private(set) var libraryRoot: String
    /// User setting, on by default: club views hide another member's notes
    /// for the chapter the reader is in and every later one.
    public private(set) var clubSpoilerProtection: Bool
    /// Stable local member identity; `nil` until first use.
    public private(set) var clubMemberId: String?
    public private(set) var clubDisplayName: String?
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
        self.clubSpoilerProtection = stored.clubSpoilerProtection ?? true
        self.clubMemberId = stored.clubMemberId
        self.clubDisplayName = stored.clubDisplayName
    }

    /// The stable local club member id, generated and persisted on first
    /// use. CloudKit accounts use their record name instead; this is the
    /// identity local-only clubs and snapshots are attributed to.
    public mutating func ensureClubMemberId() throws -> String {
        if let clubMemberId { return clubMemberId }
        let id = CoreID.newID()
        try setClubMemberId(id)
        return id
    }

    /// Records the identity a club session is actually running as (a
    /// transport member id), so offline launches keep the same id.
    public mutating func setClubMemberId(_ id: String) throws {
        guard stored.clubMemberId != id else { return }
        let previous = stored.clubMemberId
        stored.clubMemberId = id
        do {
            try persist()
        } catch {
            stored.clubMemberId = previous
            throw error
        }
        clubMemberId = id
    }

    /// Remembers the name to show other members.
    public mutating func setClubDisplayName(_ name: String) throws {
        let previous = stored.clubDisplayName
        stored.clubDisplayName = name
        do {
            try persist()
        } catch {
            stored.clubDisplayName = previous
            throw error
        }
        clubDisplayName = name
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

    /// Persists the club spoiler-protection toggle. Defaults to on; a failed
    /// save leaves the in-memory setting unchanged.
    public mutating func setClubSpoilerProtection(_ enabled: Bool) throws {
        let previous = stored.clubSpoilerProtection
        stored.clubSpoilerProtection = enabled
        do {
            try persist()
        } catch {
            stored.clubSpoilerProtection = previous
            throw error
        }
        clubSpoilerProtection = enabled
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
