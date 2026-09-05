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

    /// Deletes every note file for the book and resets its notes index;
    /// returns the number of note files removed.
    public func clearNotes(bookId: String) throws -> UInt32 {
        try core.clearNotes(bookId: bookId)
    }

    /// The book's saved reading position, or `nil` when it was never opened.
    public func readingPosition(bookId: String) throws -> ReadingPosition? {
        core.getReadingPosition(id: bookId)
    }

    /// Persists the book's reading position into the library tree.
    public func saveReadingPosition(bookId: String, position: ReadingPosition) throws {
        try core.saveReadingPosition(id: bookId, position: position)
    }

    /// Synchronous, thread-safe EPUB byte access for the reader's scheme
    /// handler, which runs on WebKit-owned threads. `MarginsCore` is
    /// `@unchecked Sendable` and internally `Mutex`-guarded, so calling it
    /// from any thread is safe.
    public nonisolated func readEpubBytesSync(id: String) throws -> Data {
        try core.readEpubBytes(id: id)
    }

    public func setLibraryRoot(path: String) throws {
        _ = try core.setLibraryRoot(path: path)
    }

    public func getChapterNote(bookId: String, chapterKey: String) throws -> ChapterNote {
        try core.getChapterNote(bookId: bookId, chapterKey: chapterKey)
    }

    /// The book's notes index (`notes/_index.json`): which chapters have
    /// notes, with word counts. Empty when the book has no notes.
    public func notesIndex(bookId: String) throws -> [NoteIndexEntry] {
        try core.getNotesIndex(bookId: bookId)
    }

    /// The book's notes compiled into one spine-ordered document.
    public func compiledNotes(bookId: String) throws -> CompiledNotes {
        try core.getCompiledNotes(bookId: bookId)
    }

    /// Renders the book's notes as markdown (the export/copy payload).
    /// `options` of `nil` uses the core defaults.
    public func renderNotesMarkdown(bookId: String, options: ExportOptions?) throws -> String {
        try core.renderNotesMarkdown(bookId: bookId, options: options)
    }

    public func saveChapterNote(
        bookId: String,
        chapter: ChapterRef,
        body: String,
        kind: String?
    ) throws -> ChapterNote {
        try core.saveChapterNote(bookId: bookId, chapter: chapter, body: body, kind: kind)
    }

    /// Appends a quick mark to the chapter's note file (creating the file
    /// when the chapter has no note yet); the core assigns id + timestamp.
    public func appendMark(
        bookId: String,
        chapterKey: String,
        cfi: String?,
        percent: Double?,
        quote: String,
        body: String
    ) throws -> Mark {
        try core.appendMark(
            bookId: bookId,
            chapterKey: chapterKey,
            cfi: cfi,
            percent: percent,
            quote: quote,
            body: body
        )
    }

    /// Replaces the mark (matched by id) in the chapter's note file.
    public func updateMark(bookId: String, chapterKey: String, mark: Mark) throws {
        try core.updateMark(bookId: bookId, chapterKey: chapterKey, mark: mark)
    }

    /// Removes the mark with `markId` from the chapter's note file.
    public func deleteMark(bookId: String, chapterKey: String, markId: String) throws {
        try core.deleteMark(bookId: bookId, chapterKey: chapterKey, markId: markId)
    }

    public func searchNotes(query: String) throws -> [NoteSearchHit] {
        try core.searchNotes(query: query)
    }
}
