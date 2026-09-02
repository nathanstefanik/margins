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

    /// Removes a book (its library directory, including notes) and
    /// refreshes; the user's original EPUB file is untouched.
    public func removeBook(id: String) async {
        guard let store else { return }
        do {
            try await store.removeBook(id: id)
            await refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Dismisses the currently displayed error.
    public func clearError() {
        errorMessage = nil
    }
}
