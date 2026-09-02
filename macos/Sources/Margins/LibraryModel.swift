import Foundation
import Observation
import MarginsCore

@MainActor
@Observable
final class LibraryModel {
    var libraryRoot = ""
    var books: [BookSummary] = []
    var errorMessage: String?

    private var store: CoreStore?

    func activate() async {
        if store == nil {
            do {
                store = try CoreStore(dataDir: nil)
            } catch {
                errorMessage = String(describing: error)
                return
            }
        }
        await refresh()
    }

    func refresh() async {
        guard let store else { return }
        do {
            libraryRoot = try await store.libraryRoot()
            books = try await store.listBooks()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
