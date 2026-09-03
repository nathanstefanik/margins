import SwiftUI
import MarginsModel

struct DetailArea: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader

    var body: some View {
        if reader.isOpen {
            ReaderView()
        } else if model.detailMode == .notes, let notes = model.compiledNotes {
            NotesPageView(notes: notes)
        } else if let book = model.selectedBook {
            BookDetailView(book: book)
        } else if model.books.isEmpty {
            ContentUnavailableView {
                Label("No books yet", systemImage: "book")
            } description: {
                Text("Import an EPUB to start your library.")
            } actions: {
                Button("Import EPUB…") {
                    Task { await ImportPanel.run(model: model) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "No book selected",
                systemImage: "sidebar.left",
                description: Text("Choose a book from the sidebar.")
            )
        }
    }
}
