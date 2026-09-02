import Foundation
import Observation
import MarginsCore

/// Model layer for the library browser. Owns the bridge store, the book
/// list, selection, and the import/remove flows.
///
/// UI-agnostic by design (no SwiftUI/AppKit) so it is unit-testable; views
/// own presentation state such as dialogs and alerts. All bridge traffic is
/// funneled through the `CoreStore` actor, keeping calls off the main actor.
@MainActor
@Observable
public final class LibraryModel {
    public private(set) var libraryRoot = ""
    public private(set) var books: [BookSummary] = []
    public private(set) var selectedBook: BookMeta?
    public private(set) var errorMessage: String?

    /// The selected book's id. Views may bind to this (e.g. sidebar list
    /// selection) and observe it; use `selectBook(id:)` for programmatic
    /// selection that also loads the book's metadata.
    public var selectedBookID: String?

    private let dataDir: String?
    private var store: CoreStore?

    /// - Parameter dataDir: explicit data directory for the Rust core, or
    ///   `nil` to let it resolve `MARGINS_DATA_DIR` / the platform default.
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
            if selectedBookID != nil, books.contains(where: { $0.id == selectedBookID }) {
                await loadSelectedBook()
            } else {
                selectedBook = nil
                selectedBookID = nil
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Fetches the selected book's metadata from the bridge.
    public func loadSelectedBook() async {
        guard let store, let selectedBookID else { return }
        do {
            selectedBook = try await store.getBook(id: selectedBookID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Programmatically selects a book and loads its metadata.
    public func selectBook(id: String?) async {
        selectedBookID = id
        if id != nil {
            await loadSelectedBook()
        } else {
            selectedBook = nil
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

    /// Dismisses the currently displayed error.
    public func clearError() {
        errorMessage = nil
    }

    /// A thread-safe provider of raw EPUB bytes for the reader's scheme
    /// handler. Call once on the main actor when creating the reader.
    public func makeReaderBytesProvider() throws -> @Sendable (String) throws -> Data {
        guard let store else {
            throw CoreError.Message(message: "library is not open yet")
        }
        return { bookID in
            try store.readEpubBytesSync(id: bookID)
        }
    }

    // MARK: Notes (Part III)

    public private(set) var searchRequest = 0

    /// Asks the UI to present the note search sheet.
    public func requestSearch() {
        searchRequest += 1
    }

    /// Loads the note for the reader's current chapter into its state.
    public func loadChapterNote(reader: ReaderModel) async {
        guard let store, let book = reader.book, let chapter = reader.chapter else { return }
        do {
            let note = try await store.getChapterNote(bookId: book.id, chapterKey: chapter.key)
            reader.noteLoaded(
                body: note.body,
                path: note.path.isEmpty ? nil : note.path,
                wordCount: note.frontmatter.wordCount,
                updatedAt: note.frontmatter.updatedAt
            )
        } catch {
            reader.noteFailed(String(describing: error))
        }
    }

    /// Saves the reader's current note body (markdown + YAML frontmatter).
    public func saveChapterNote(reader: ReaderModel) async {
        guard let store, let book = reader.book, let chapter = reader.chapter else { return }
        let ref = ChapterRef(key: chapter.key, epubCfi: nil)
        do {
            let note = try await store.saveChapterNote(
                bookId: book.id,
                chapter: ref,
                body: reader.noteBody,
                kind: nil
            )
            reader.noteSaved(
                path: note.path,
                wordCount: note.frontmatter.wordCount,
                updatedAt: note.frontmatter.updatedAt
            )
        } catch {
            reader.noteFailed(String(describing: error))
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
