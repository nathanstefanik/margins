import SwiftUI
import MarginsModel

struct DetailArea: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader

    var body: some View {
        if reader.isOpen {
            ReaderView()
        } else if let book = model.selectedBook {
            BookDetailView(book: book)
        } else if model.books.isEmpty {
            ContentUnavailableView(
                "No books yet",
                systemImage: "book",
                description: Text("Import an EPUB with File ▸ Import EPUB… (⌘O).")
            )
        } else {
            ContentUnavailableView(
                "No book selected",
                systemImage: "sidebar.left",
                description: Text("Choose a book from the sidebar.")
            )
        }
    }
}
