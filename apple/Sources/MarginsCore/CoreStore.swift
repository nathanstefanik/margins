import Foundation

/// Actor facade over the Swift core — what the apps talk to.
///
/// The core's entry points are synchronous and do real file I/O (notably
/// `importEpub`), so calls must stay off the main actor. `AppConfig` and
/// `Library` live inside the actor and every call is funneled through the
/// actor's executor; `Library` in turn owns the `SearchEngine`.
public actor CoreStore {
    private var config: AppConfig
    private let library: Library

    /// The library root as `readEpubBytesSync` sees it. That call must not
    /// hop through the actor (the reader's scheme handler invokes it
    /// synchronously from WebKit threads), so the root it reads is carried
    /// outside actor isolation behind a lock and kept in step by
    /// `setLibraryRoot`.
    private nonisolated let readerRoot = ReaderRoot("")

    private final class ReaderRoot: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String

        init(_ path: String) {
            self.path = path
        }

        var current: String {
            get { lock.withLock { path } }
            set { lock.withLock { path = newValue } }
        }
    }

    /// - Parameter dataDir: explicit data directory, or `nil` to let the core
    ///   resolve `MARGINS_DATA_DIR` / the platform default.
    public init(dataDir: String?) throws {
        let config = try AppConfig(dataDir: dataDir)
        self.config = config
        self.library = try Library(root: config.libraryRoot)
        readerRoot.current = config.libraryRoot
    }

    public func dataDir() throws -> String {
        config.dataDir
    }

    public func libraryRoot() throws -> String {
        library.root
    }

    public func setLibraryRoot(path: String) throws {
        let previous = library.root
        try library.setRoot(path)
        do {
            try config.setLibraryRoot(path)
        } catch let configError {
            // A failed save must not leave the two halves pointing at
            // different roots; restore the active library first.
            do {
                try library.setRoot(previous)
            } catch let restoreError {
                throw CoreError.config(
                    "could not save library directory: \(Self.message(of: configError)); "
                        + "could not restore active directory: \(Self.message(of: restoreError))"
                )
            }
            throw configError
        }
        readerRoot.current = path
    }

    /// The core only ever throws `CoreError`; this keeps the message even if
    /// a future wrapped error leaks through.
    private static func message(of error: any Error) -> String {
        (error as? CoreError)?.message ?? error.localizedDescription
    }

    public func listBooks() throws -> [BookSummary] {
        try library.listBooks()
    }

    public func importEpub(atPath path: String) throws -> BookMeta {
        try library.importEpub(atPath: path)
    }

    public func getBook(id: String) throws -> BookMeta {
        try library.getBook(id: id)
    }

    public func removeBook(id: String) throws {
        try library.removeBook(id: id)
    }

    /// Deletes every note file for the book and resets its notes index;
    /// returns the number of note files removed.
    public func clearNotes(bookId: String) throws -> Int {
        let bookDir = library.bookDir(bookId)
        guard Files.isDirectory(bookDir) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        let cleared = try Notes.clearBookNotes(bookDir: bookDir)
        // Keep the search index warm: update this book's docs in place.
        library.refreshNoteIndex(bookID: bookId)
        return cleared
    }

    /// The book's saved reading position, or `nil` when it was never opened.
    public func readingPosition(bookId: String) throws -> ReadingPosition? {
        library.readPosition(bookID: bookId)
    }

    /// Persists the book's reading position into the library tree.
    public func saveReadingPosition(bookId: String, position: ReadingPosition) throws {
        try library.writePosition(bookID: bookId, position: position)
    }

    /// Synchronous, thread-safe EPUB byte access for the reader's scheme
    /// handler, which runs on WebKit-owned threads: the path comes from the
    /// lock-guarded root above, never from actor state.
    public nonisolated func readEpubBytesSync(id: String) throws -> Data {
        try Library.readEpubBytes(bookId: id, root: readerRoot.current)
    }

    public func getChapterNote(bookId: String, chapterKey: String) throws -> ChapterNote {
        try Notes.loadChapterNote(
            bookDir: library.bookDir(bookId), chapterKey: chapterKey
        )
    }

    /// The book's notes index (`notes/_index.json`): which chapters have
    /// notes, with word counts. Empty when the book has no notes.
    public func notesIndex(bookId: String) throws -> [NotesIndexEntry] {
        let bookDir = library.bookDir(bookId)
        guard Files.isDirectory(bookDir) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        return try Notes.readIndex(bookDir: bookDir).chapters
    }

    /// The book's notes compiled into one spine-ordered document.
    public func compiledNotes(bookId: String) throws -> CompiledNotes {
        let bookDir = library.bookDir(bookId)
        guard FileStore.exists(bookDir.appendingPathComponent("meta.json")) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        return try Compile.bookNotes(bookDir: bookDir)
    }

    /// Renders the book's notes as markdown (the export/copy payload).
    /// `options` of `nil` uses the core defaults.
    public func renderNotesMarkdown(bookId: String, options: ExportOptions?) throws -> String {
        let bookDir = library.bookDir(bookId)
        guard FileStore.exists(bookDir.appendingPathComponent("meta.json")) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        let compiled = try Compile.bookNotes(bookDir: bookDir)
        return Compile.renderMarkdown(compiled, options: options ?? .default)
    }

    public func saveChapterNote(
        bookId: String,
        chapter: ChapterRef,
        body: String,
        kind: String?
    ) throws -> ChapterNote {
        let bookDir = library.bookDir(bookId)
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapter.key)
        let frontmatter = NoteFrontmatter(
            bookId: bookId,
            chapterKey: chapterMeta.key,
            chapterIndex: chapterMeta.index,
            chapterTitle: chapterMeta.title,
            chapterHref: chapterMeta.href,
            epubCfi: chapter.epubCfi,
            kind: kind ?? "summary",
            wordCount: Notes.countWords(body)
        )
        let saved = try Notes.saveChapterNote(
            bookDir: bookDir, chapter: chapterMeta, frontmatter: frontmatter, body: body
        )
        // Keep the search index warm: update this book's docs in place.
        library.refreshNoteIndex(bookID: bookId)
        return saved
    }

    /// Appends a quick mark to the chapter's note file (creating the file
    /// when the chapter has no note yet); the core assigns id + timestamp.
    @discardableResult
    public func appendMark(
        bookId: String,
        chapterKey: String,
        cfi: String?,
        percent: Double?,
        quote: String,
        body: String
    ) throws -> Mark {
        let bookDir = library.bookDir(bookId)
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapterKey)
        let mark = try Notes.appendMark(
            bookDir: bookDir,
            chapter: chapterMeta,
            cfi: cfi,
            percent: percent,
            quote: quote,
            body: body
        )
        library.refreshNoteIndex(bookID: bookId)
        return mark
    }

    /// Replaces the mark (matched by id) in the chapter's note file.
    public func updateMark(bookId: String, chapterKey: String, mark: Mark) throws {
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapterKey)
        try Notes.updateMark(
            bookDir: library.bookDir(bookId), chapter: chapterMeta, mark: mark
        )
        library.refreshNoteIndex(bookID: bookId)
    }

    /// Removes the mark with `markId` from the chapter's note file.
    public func deleteMark(bookId: String, chapterKey: String, markId: String) throws {
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapterKey)
        try Notes.deleteMark(
            bookDir: library.bookDir(bookId), chapter: chapterMeta, id: markId
        )
        library.refreshNoteIndex(bookID: bookId)
    }

    public func searchNotes(query: String) throws -> [NoteSearchHit] {
        library.searchNotes(query: query)
    }

    /// The spine's chapter record for a key, or an error for unknown keys.
    private func resolveChapter(bookId: String, chapterKey: String) throws -> ChapterMeta {
        let meta = try library.getBook(id: bookId)
        guard let chapter = meta.chapters.first(where: { $0.key == chapterKey }) else {
            throw CoreError.notes("unknown chapter key: \(chapterKey)")
        }
        return chapter
    }
}
