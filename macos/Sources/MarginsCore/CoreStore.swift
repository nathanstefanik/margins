import Foundation

/// Actor wrapper around the nonisolated `MarginsCore` bridge object.
///
/// The UniFFI surface is synchronous and does real file I/O (notably
/// `importEpub`), so calls must stay off the main actor. `MarginsCore` is
/// `@unchecked Sendable`, so it can live inside the actor and every call is
/// funneled through the actor's executor.
public actor CoreStore {
    private nonisolated let core: MarginsCore

    /// - Parameter dataDir: explicit data directory, or `nil` to let the Rust
    ///   core resolve `MARGINS_DATA_DIR` / the platform default.
    public init(dataDir: String?) throws {
        self.core = try MarginsCore(dataDir: dataDir)
    }

    public func dataDir() throws -> String {
        try core.dataDir()
    }

    public func libraryRoot() throws -> String {
        try core.libraryRoot()
    }

    public func listBooks() throws -> [BookSummary] {
        try core.listBooks()
    }

    public func importEpub(atPath path: String) throws -> BookMeta {
        try core.importEpub(path: path)
    }

    public func getBook(id: String) throws -> BookMeta {
        try core.getBook(id: id)
    }

    public func removeBook(id: String) throws {
        try core.removeBook(id: id)
    }

    /// Synchronous, thread-safe EPUB byte access for the reader's scheme
    /// handler, which runs on WebKit-owned threads. `MarginsCore` is
    /// `@unchecked Sendable` and internally `Mutex`-guarded, so calling it
    /// from any thread is safe.
    public nonisolated func readEpubBytesSync(id: String) throws -> Data {
        try core.readEpubBytes(id: id)
    }
}
