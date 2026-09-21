import Foundation
import Observation
import MarginsCore

/// Model layer for the library browser. Owns the core store, the book
/// list, selection, and the import/remove flows.
///
/// UI-agnostic by design (no SwiftUI/AppKit) so it is unit-testable; views
/// own presentation state such as dialogs and alerts. All core traffic is
/// funneled through the `CoreStore` actor, keeping calls off the main actor.
@MainActor
@Observable
public final class LibraryModel {
    public private(set) var libraryRoot = ""
    public private(set) var books: [BookSummary] = []
    public private(set) var notDownloadedBookIDs: [String] = []
    public private(set) var selectedBook: BookMeta?
    /// The selected book's notes index (`notes/_index.json`), loaded with
    /// the book so the detail view can flag chapters that have notes.
    public private(set) var selectedBookNotesIndex: [NotesIndexEntry] = []
    /// Named location pins for the selected book (`bookmarks.json`).
    public private(set) var selectedBookBookmarks: [Bookmark] = []
    /// The last non-fatal failure, surfaced as a transient banner.
    /// Model methods set it; AppKit-level flows (save panel, clipboard)
    /// set it from the view layer so the banner stays the single sink.
    public var errorMessage: String?

    /// The selected book's id. Views may bind to this (e.g. sidebar list
    /// selection) and observe it; use `selectBook(id:)` for programmatic
    /// selection that also loads the book's metadata.
    public var selectedBookID: String?

    private let dataDir: String?
    private var store: CoreStore?

    /// The underlying core store once `activate()` ran. Sibling models
    /// (clubs) share this one actor instead of opening a second store over
    /// the same files.
    public var coreStore: CoreStore? { store }

    /// Fired after a note or mark lands on disk. Clubs debounce-publish from here.
    public var onBookNotesChanged: ((String) async -> Void)?

    /// - Parameter dataDir: explicit data directory for the core, or `nil`
    ///   to let it resolve `MARGINS_DATA_DIR` / the platform default.
    public init(dataDir: String? = nil) {
        self.dataDir = dataDir
    }

    /// Opens the bridge store and performs the initial load.
    public func activate() async {
        if store == nil {
            do {
                store = try CoreStore(dataDir: dataDir)
            } catch {
                errorMessage = String(describing: error)
                return
            }
        }
        await refresh()
    }

    /// Reloads the book list; keeps the selection if the book still exists,
    /// clears it otherwise.
    public func refresh() async {
        guard let store else { return }
        do {
            libraryRoot = try await store.libraryRoot()
            books = try await store.listBooks()
            notDownloadedBookIDs = await store.notDownloadedBookIDs()
            for id in notDownloadedBookIDs {
                LibraryLocation.requestDownload(bookFilePath(id, "meta.json"))
            }
            if selectedBookID != nil, books.contains(where: { $0.id == selectedBookID }) {
                await loadSelectedBook()
            } else {
                selectedBook = nil
                selectedBookID = nil
                selectedBookNotesIndex = []
                selectedBookBookmarks = []
                compiledNotes = nil
                detailMode = .book
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Fetches the selected book's metadata from the bridge.
    public func loadSelectedBook() async {
        guard let store, let selectedBookID else { return }
        let bookId = selectedBookID
        do {
            let book = try await store.getBook(id: bookId)
            let notes = try await store.notesIndex(bookId: bookId)
            let bookmarks = try await store.bookmarks(bookId: bookId)
            guard self.selectedBookID == bookId else { return }
            selectedBook = book
            selectedBookNotesIndex = notes
            selectedBookBookmarks = bookmarks
            // A compiled page for a previous selection must never survive
            // the selection changing underneath it.
            if compiledNotes?.bookId != bookId {
                compiledNotes = nil
                detailMode = .book
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Programmatically selects a book and loads its metadata.
    public func selectBook(id: String?) async {
        if selectedBookID != id {
            selectedBookBookmarks = []
        }
        selectedBookID = id
        if id != nil {
            await loadSelectedBook()
        } else {
            selectedBook = nil
            selectedBookNotesIndex = []
            selectedBookBookmarks = []
            compiledNotes = nil
            detailMode = .book
        }
    }

    /// Points the library at a new root directory and reloads. The books and
    /// notes move with the directory; the selection does not survive it.
    public func setLibraryRoot(_ path: String) async {
        guard let store else { return }
        do {
            try await store.setLibraryRoot(path: path)
            selectedBookID = nil
            selectedBook = nil
            selectedBookNotesIndex = []
            selectedBookBookmarks = []
            compiledNotes = nil
            detailMode = .book
            await refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Maps a book's chapters to the word counts of their notes, joined from
    /// the notes index. Chapters without notes are absent from the result.
    public static func noteWordCounts(
        chapters: [ChapterMeta],
        index: [NotesIndexEntry]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in index {
            counts[entry.chapterKey] = entry.wordCount
        }
        return chapters.reduce(into: [:]) { result, chapter in
            if let count = counts[chapter.key] {
                result[chapter.key] = count
            }
        }
    }

    /// One row of the book detail's "Show Notes" list: a chapter that has a
    /// note, joined with the note's stats from `_index.json`.
    public struct ChapterNoteRow: Equatable, Sendable {
        public var chapter: ChapterMeta
        public var wordCount: Int
        public var updatedAt: Date?

        public init(chapter: ChapterMeta, wordCount: Int, updatedAt: Date?) {
            self.chapter = chapter
            self.wordCount = wordCount
            self.updatedAt = updatedAt
        }
    }

    /// The spine's annotated chapters in spine order (never reordered by
    /// note presence), each joined with its note's word count and updated
    /// date. Pure so the views and tests share one definition.
    public nonisolated static func annotatedChapterRows(
        chapters: [ChapterMeta],
        index: [NotesIndexEntry]
    ) -> [ChapterNoteRow] {
        let byKey = Dictionary(index.map { ($0.chapterKey, $0) }, uniquingKeysWith: { first, _ in first })
        return chapters.compactMap { chapter in
            guard let entry = byKey[chapter.key] else { return nil }
            return ChapterNoteRow(
                chapter: chapter,
                wordCount: entry.wordCount,
                updatedAt: entry.updatedAt
            )
        }
    }

    /// Imports an EPUB, refreshes the list, and selects the new book.
    /// Returns whether the import succeeded; failures surface in
    /// `errorMessage` for the UI to present.
    @discardableResult
    public func importEpub(atPath path: String) async -> Bool {
        guard let store else { return false }
        do {
            let imported = try await store.importEpub(atPath: path)
            await refresh()
            await selectBook(id: imported.id)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Human-readable progress for a running import, e.g.
    /// "Importing 2 of 3: karamazov.epub" — nil when idle.
    public private(set) var importStatus: String?

    /// Imports several EPUBs in turn, surfacing per-file progress for the
    /// sidebar. One failed file does not stop the rest. Returns the ids
    /// that landed; macOS ignores the value.
    @discardableResult
    public func importEpubs(atPaths paths: [String]) async -> [String] {
        var ids: [String] = []
        for (offset, path) in paths.enumerated() {
            let name = URL(fileURLWithPath: path).lastPathComponent
            importStatus = paths.count > 1
                ? "Importing \(offset + 1) of \(paths.count): \(name)"
                : "Importing \(name)…"
            if await importEpub(atPath: path), let id = selectedBookID {
                ids.append(id)
            }
        }
        importStatus = nil
        return ids
    }

    /// The reader state this library drives. Wired once at app startup so
    /// removals can close the reader when its book disappears.
    public weak var reader: ReaderModel?

    /// Removes a book (its library directory, including notes) and
    /// refreshes; the user's original EPUB file is untouched.
    public func removeBook(id: String) async {
        guard let store else { return }
        do {
            try await store.removeBook(id: id)
            if reader?.book?.id == id {
                reader?.close()
            }
            await refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Deletes every note file for the book, then refreshes. The open
    /// reader's note editor (if any) is reloaded from disk so a stale body
    /// cannot resurrect a cleared note on the next autosave. Returns the
    /// number of note files removed, or `nil` on failure (surfaced in
    /// `errorMessage`).
    @discardableResult
    public func clearNotes(bookId: String) async -> Int? {
        guard let store else { return nil }
        do {
            let cleared = try await store.clearNotes(bookId: bookId)
            if let reader, reader.book?.id == bookId {
                await loadChapterNote(reader: reader)
            }
            await refresh()
            // A compiled page cached for this book must reflect the clear
            // immediately: `refresh()` deliberately keeps `compiledNotes`
            // when the bookId still matches, so the notes view would keep
            // showing deleted notes until the next navigation.
            await recompileCompiledNotesIfCached(bookId: bookId)
            return cleared
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Opens a book at its saved reading position (chapter + CFI), falling
    /// back to the first chapter for books never opened. Used by Enter,
    /// double-click, and the detail view's Read button; explicit chapter
    /// jumps still open that chapter directly.
    public func openBookResuming(id bookID: String) async {
        await selectBook(id: bookID)
        guard let book = selectedBook, !book.chapters.isEmpty, let reader else { return }
        var target = book.chapters[0]
        var cfi: String?
        if let store,
           let position = try? await store.readingPosition(bookId: book.id),
           let saved = book.chapters.first(where: { $0.key == position.chapterKey }) {
            target = saved
            cfi = position.epubCfi
        }
        reader.open(book: book, chapter: target)
        reader.resume(at: cfi)
        await loadBookmarks(reader: reader)
    }

    /// Absolute path of `books/{id}/source.epub` under the current library
    /// root. The iOS app materializes this before the core reads it.
    public func sourceEpubPath(for bookId: String) -> String {
        bookFilePath(bookId, "source.epub")
    }

    private func bookFilePath(_ bookId: String, _ fileName: String) -> String {
        URL(fileURLWithPath: libraryRoot)
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookId, isDirectory: true)
            .appendingPathComponent(fileName)
            .path
    }

    /// Opens a book at a specific chapter (and CFI, when one is known).
    /// Search hits and compiled-note marks share this so a thought lands
    /// on the sentence rather than the book card. `chapterKey` empty means
    /// a book-level target: first chapter, no CFI. `fragment` targets a
    /// section inside the chapter's file (an outline row).
    public func openPassage(
        bookId: String,
        chapterKey: String,
        cfi: String?,
        fragment: String? = nil
    ) async {
        await selectBook(id: bookId)
        guard let book = selectedBook, let reader else { return }
        let chapter: ChapterMeta?
        if chapterKey.isEmpty {
            chapter = book.chapters.first
        } else {
            chapter = book.chapters.first(where: { $0.key == chapterKey })
        }
        guard let chapter else { return }
        reader.open(book: book, chapter: chapter, fragment: fragment)
        reader.resume(at: (cfi?.isEmpty ?? true) ? nil : cfi)
        pendingReaderPresent = true
        passageJumpGeneration += 1
        await loadBookmarks(reader: reader)
    }

    /// True when a passage jump should also push the reader scene. Views
    /// consume it by presenting, then clear it.
    public var pendingReaderPresent = false

    /// Bumped on every `openPassage` so an already-visible reader can
    /// retarget (JS display or a fresh book load) without rebuilding.
    public private(set) var passageJumpGeneration = 0

    /// Persists a reading position (called from the reader's debounce).
    public func saveReadingPosition(bookId: String, position: ReadingPosition) async {
        guard let store else { return }
        try? await store.saveReadingPosition(bookId: bookId, position: position)
    }

    /// The book's saved reading position, or nil when it was never opened.
    /// Drives the detail view's current-position marker and Continue label.
    public func readingPosition(bookId: String) async -> ReadingPosition? {
        guard let store else { return nil }
        return try? await store.readingPosition(bookId: bookId)
    }

    /// Moves the sidebar selection by `delta` books (shell keyboard j/k).
    public func moveLibrarySelection(_ delta: Int) {
        guard !books.isEmpty else { return }
        let ids = books.map(\.id)
        let currentIndex = selectedBookID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let next = min(max(currentIndex + delta, 0), ids.count - 1)
        guard ids[next] != selectedBookID else { return }
        selectedBookID = ids[next]
        Task { await loadSelectedBook() }
    }

    /// The palette's query lifecycle (debounce, cap, recents).
    public let search = SearchController()

    /// Dismisses the currently displayed error.
    public func clearError() {
        errorMessage = nil
    }

    /// A thread-safe provider of raw EPUB bytes for the reader's scheme
    /// handler. Call once on the main actor when creating the reader.
    public func makeReaderBytesProvider() throws -> @Sendable (String) throws -> Data {
        guard let store else {
            throw CoreError.library("library is not open yet")
        }
        return { bookID in
            try store.readEpubBytesSync(id: bookID)
        }
    }

    // MARK: Compiled notes page

    /// What the detail area shows when no reader session is open: the
    /// book's detail card or its compiled notes page.
    public enum DetailMode: Equatable, Sendable {
        case book
        case notes
    }

    public private(set) var detailMode: DetailMode = .book
    /// The selected book's compiled notes; loaded by `loadCompiledNotes`.
    public private(set) var compiledNotes: CompiledNotes?

    /// Which face of the compiled notes page is showing: the outline
    /// (chapter/title list) or the contents (compiled markdown view).
    /// Lives here (not in view state) so the shell keyboard can flip it
    /// with `t`.
    public enum NotesPageTab: Equatable, Sendable {
        case outline
        case contents
    }

    public private(set) var notesPageTab: NotesPageTab = .contents

    /// Flips between the outline and the contents view.
    public func toggleNotesPageTab() {
        notesPageTab = notesPageTab == .outline ? .contents : .outline
    }

    public func showNotesPageTab(_ tab: NotesPageTab) {
        notesPageTab = tab
    }

    /// Compiles the book's notes and switches the detail area to the notes
    /// page. Returns the compilation, or `nil` on failure (surfaced in
    /// `errorMessage`).
    @discardableResult
    public func loadCompiledNotes(bookId: String) async -> CompiledNotes? {
        guard let store else { return nil }
        do {
            let notes = try await store.compiledNotes(bookId: bookId)
            compiledNotes = notes
            detailMode = .notes
            notesPageTab = .contents
            return notes
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Back to the book's detail card (kept out of `selectBook` so views
    /// can return without reloading).
    public func showBookDetail() {
        detailMode = .book
    }

    /// Renders the book's notes as markdown for export/copy. Runs through
    /// the `CoreStore` actor, so the compile happens off the main actor.
    public func renderNotesMarkdown(bookId: String) async throws -> String {
        guard let store else {
            throw CoreError.library("library is not open yet")
        }
        return try await store.renderNotesMarkdown(bookId: bookId, options: nil)
    }

    /// One-line coverage summary, e.g.
    /// "3/5 chapters annotated · 1,240 words · last updated Sep 1, 2026".
    /// Pure (nonisolated) so tests can cover it without UI; matches the
    /// export's stats line (modulo the author, which the page shows in its
    /// header).
    public nonisolated static func statsLine(for notes: CompiledNotes) -> String {
        var parts = [
            "\(notes.chaptersWithNotes)/\(notes.chapterCount) chapters annotated",
            "\(groupedCount(notes.totalWords)) words",
        ]
        if let updated = notes.lastUpdatedAt {
            parts.append("last updated \(dateText(updated))")
        }
        return parts.joined(separator: " · ")
    }

    /// Thousands-grouped count with a fixed separator so the line does not
    /// depend on the user's locale.
    public nonisolated static func groupedCount(_ value: Int) -> String {
        let digits = String(value)
        var grouped = ""
        for (offset, char) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                grouped.insert(",", at: grouped.startIndex)
            }
            grouped.insert(char, at: grouped.startIndex)
        }
        return grouped
    }

    /// Fixed-locale "Sep 1, 2026" date text for the stats line.
    public nonisolated static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    // MARK: Notes (Part III)

    /// Whether the note search overlay is presented. Owned here rather
    /// than in view state so the UI and the shell key monitor drive the
    /// same flag: the monitor closes the overlay on Esc because the search
    /// field's AppKit field editor consumes the key before any SwiftUI
    /// handler can see it.
    public var searchOpen = false {
        didSet {
            if searchOpen {
                helpOpen = false
                bookmarksOpen = false
            }
        }
    }

    /// Whether the keyboard-shortcuts cheat sheet is presented; mutually
    /// exclusive with the search palette and the bookmarks overlay.
    public var helpOpen = false {
        didSet {
            if helpOpen {
                searchOpen = false
                bookmarksOpen = false
            }
        }
    }

    /// Whether the bookmarks overlay is presented (macOS). Mutually
    /// exclusive with search and help; the shell monitor closes it on Esc.
    public var bookmarksOpen = false {
        didSet {
            if bookmarksOpen {
                searchOpen = false
                helpOpen = false
            }
        }
    }

    /// Presents the note search overlay (`/`, ⌘F).
    public func requestSearch() {
        searchOpen = true
    }

    /// Dismisses the note search overlay (Esc, click outside, opening a hit).
    public func requestSearchDismissal() {
        searchOpen = false
    }

    /// Presents the keyboard-shortcuts cheat sheet (`?`, Help menu).
    public func requestHelp() {
        helpOpen = true
    }

    /// Dismisses the cheat sheet (Esc, click outside).
    public func requestHelpDismissal() {
        helpOpen = false
    }

    /// Presents the bookmarks overlay (`B`).
    public func requestBookmarks() {
        bookmarksOpen = true
    }

    /// Dismisses the bookmarks overlay (Esc, click outside, opening a pin).
    public func requestBookmarksDismissal() {
        bookmarksOpen = false
    }

    /// Loads the note for the reader's current chapter into its state.
    public func loadChapterNote(reader: ReaderModel) async {
        guard let store, let book = reader.book, let chapter = reader.chapter else { return }
        do {
            let note = try await store.getChapterNote(bookId: book.id, chapterKey: chapter.key)
            reader.noteLoaded(
                body: note.body,
                marks: note.marks,
                path: note.path.isEmpty ? nil : note.path,
                wordCount: note.frontmatter.wordCount,
                updatedAt: note.frontmatter.updatedAt
            )
        } catch {
            reader.noteFailed(String(describing: error))
        }
    }

    /// Appends a quick mark to the reader's current chapter note (creating
    /// the note file when the chapter has none). The core assigns the id
    /// and timestamp; the returned `Mark` carries them.
    @discardableResult
    public func appendMark(
        bookId: String,
        chapterKey: String,
        cfi: String?,
        percent: Double?,
        quote: String,
        body: String,
        reader: ReaderModel
    ) async -> Mark? {
        guard let store else { return nil }
        do {
            let mark = try await store.appendMark(
                bookId: bookId,
                chapterKey: chapterKey,
                cfi: cfi,
                percent: percent,
                quote: quote,
                body: body
            )
            reader.noteMarksUpdated(reader.noteMarks + [mark])
            await notesDidChange(bookId: bookId)
            return mark
        } catch {
            self.reader?.noteFailed(String(describing: error))
            return nil
        }
    }

    /// Deletes a quick mark from the reader's current chapter note. The
    /// editor body is untouched (prose and marks are disjoint); the mark
    /// list and any open compiled page refresh.
    public func deleteMark(_ mark: Mark, reader: ReaderModel) async {
        guard let store, let book = reader.book, let chapter = reader.chapter else { return }
        do {
            try await store.deleteMark(bookId: book.id, chapterKey: chapter.key, markId: mark.id)
            reader.noteMarksUpdated(reader.noteMarks.filter { $0.id != mark.id })
            await notesDidChange(bookId: book.id)
        } catch {
            reader.noteFailed(String(describing: error))
        }
    }

    /// Replaces a quick mark's text in the reader's current chapter note.
    public func updateMark(_ mark: Mark, body: String, reader: ReaderModel) async {
        guard let store, let book = reader.book, let chapter = reader.chapter else { return }
        do {
            var updated = mark
            updated.body = body
            try await store.updateMark(bookId: book.id, chapterKey: chapter.key, mark: updated)
            reader.noteMarksUpdated(
                reader.noteMarks.map { $0.id == mark.id ? updated : $0 }
            )
            await notesDidChange(bookId: book.id)
        } catch {
            reader.noteFailed(String(describing: error))
        }
    }

    /// Saves the reader's current note body (markdown + YAML frontmatter).
    public func saveChapterNote(reader: ReaderModel) async {
        guard let store, let book = reader.book, let chapter = reader.chapter else { return }
        let body = reader.noteBody
        let ref = ChapterRef(key: chapter.key, epubCfi: nil)
        do {
            let note = try await store.saveChapterNote(
                bookId: book.id,
                chapter: ref,
                body: body,
                kind: nil
            )
            reader.noteSaved(
                path: note.path,
                wordCount: note.frontmatter.wordCount,
                updatedAt: note.frontmatter.updatedAt,
                savedBody: body
            )
            await notesDidChange(bookId: book.id)
        } catch {
            reader.noteFailed(String(describing: error))
        }
    }

    /// Autosave target: persists an editor snapshot for a specific chapter,
    /// independent of the reader's *current* chapter (which may already have
    /// moved on by the time a debounced save fires).
    public func saveChapterNoteText(bookId: String, chapterKey: String, body: String) async {
        guard let store else { return }
        do {
            let book = try await store.getBook(id: bookId)
            guard let chapter = book.chapters.first(where: { $0.key == chapterKey }) else { return }
            let note = try await store.saveChapterNote(
                bookId: bookId,
                chapter: ChapterRef(key: chapter.key, epubCfi: nil),
                body: body,
                kind: nil
            )
            reader?.noteSaved(
                path: note.path,
                wordCount: note.frontmatter.wordCount,
                updatedAt: note.frontmatter.updatedAt,
                savedBody: body
            )
            await notesDidChange(bookId: bookId)
        } catch {
            reader?.noteFailed(String(describing: error))
        }
    }

    private func notesDidChange(bookId: String) async {
        await refreshCompiledNotesAfterSave(bookId: bookId)
        await onBookNotesChanged?(bookId)
    }

    /// The compiled notes page keeps its snapshot while a reader session
    /// is open on top of it (`detailMode` stays `.notes` and Esc falls back
    /// to the page), so a save recompiles it in the background and
    /// returning to the page shows the new content. The outline/contents
    /// tab choice is preserved.
    private func refreshCompiledNotesAfterSave(bookId: String) async {
        guard detailMode == .notes, compiledNotes?.bookId == bookId else { return }
        await recompileCompiledNotesIfCached(bookId: bookId)
    }

    /// Recompiles a cached compiled-notes page for `bookId` in the
    /// background of a save/clear, without disturbing what the detail area
    /// shows (`loadCompiledNotes` itself flips `detailMode` and resets the
    /// tab — recompile-only callers must not).
    private func recompileCompiledNotesIfCached(bookId: String) async {
        guard compiledNotes?.bookId == bookId else { return }
        let mode = detailMode
        let tab = notesPageTab
        guard (await loadCompiledNotes(bookId: bookId)) != nil else { return }
        detailMode = mode
        notesPageTab = tab
    }

    // MARK: Bookmarks

    /// Reloads the open book's pins into the reader (and the selected-book
    /// list when that book is selected).
    public func loadBookmarks(reader: ReaderModel) async {
        guard let store, let book = reader.book else { return }
        let bookId = book.id
        let list = (try? await store.bookmarks(bookId: bookId)) ?? []
        guard reader.book?.id == bookId else { return }
        reader.bookmarksUpdated(list)
        if selectedBookID == bookId {
            selectedBookBookmarks = list
        }
    }

    @discardableResult
    public func addBookmark(
        bookId: String,
        label: String = "",
        position: ReadingPosition,
        reader: ReaderModel? = nil
    ) async -> Bookmark? {
        guard let store else { return nil }
        do {
            let bookmark = try await store.addBookmark(
                bookId: bookId, label: label, position: position
            )
            await rememberBookmarks(bookId: bookId, reader: reader)
            if let reader {
                await stampBookmarkPositions(reader: reader)
            }
            return bookmark
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    @discardableResult
    public func updateBookmark(
        _ bookmark: Bookmark,
        bookId: String,
        label: String? = nil,
        position: ReadingPosition? = nil,
        reader: ReaderModel? = nil
    ) async -> Bookmark? {
        guard let store else { return nil }
        do {
            let updated = try await store.updateBookmark(
                bookId: bookId, id: bookmark.id, label: label, position: position
            )
            await rememberBookmarks(bookId: bookId, reader: reader)
            return updated
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Pins dropped before the first `relocated` event have no CFI and a
    /// chapter-index percent. Once the renderer reports a location, restamp
    /// those pins onto the real page so the chrome and jumps match.
    public func stampBookmarkPositions(reader: ReaderModel) async {
        guard let book = reader.book,
              let chapter = reader.chapter,
              let position = reader.currentPosition(),
              !(position.epubCfi?.isEmpty ?? true)
        else { return }
        let incomplete = reader.bookmarks.filter {
            $0.chapterKey == chapter.key && ($0.epubCfi == nil || $0.epubCfi?.isEmpty == true)
        }
        for pin in incomplete {
            _ = await updateBookmark(
                pin, bookId: book.id, position: position, reader: reader
            )
        }
    }

    public func deleteBookmark(
        _ bookmark: Bookmark, bookId: String, reader: ReaderModel? = nil
    ) async {
        guard let store else { return }
        do {
            try await store.deleteBookmark(bookId: bookId, id: bookmark.id)
            await rememberBookmarks(bookId: bookId, reader: reader)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func rememberBookmarks(bookId: String, reader: ReaderModel?) async {
        guard let store else { return }
        let list = (try? await store.bookmarks(bookId: bookId)) ?? []
        if selectedBookID == bookId {
            selectedBookBookmarks = list
        }
        if let reader, reader.book?.id == bookId {
            reader.bookmarksUpdated(list)
        }
    }

    public func searchNotes(_ query: String) async -> [NoteSearchHit] {
        guard let store, !query.isEmpty else { return [] }
        do {
            return try await store.searchNotes(query: query)
        } catch {
            errorMessage = String(describing: error)
            return []
        }
    }

    public func getBook(id: String) async -> BookMeta? {
        guard let store else { return nil }
        return try? await store.getBook(id: id)
    }
}
