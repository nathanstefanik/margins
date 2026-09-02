import SwiftUI
import MarginsCore
import MarginsModel

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model
    @State private var showingRemovalDialog = false
    @State private var bookPendingRemoval: BookSummary?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedBookID) {
            ForEach(model.books) { book in
                BookRowView(book: book)
                    .tag(book.id)
                    .contextMenu {
                        Button("Remove…", role: .destructive) {
                            requestRemoval(of: book)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .overlay(alignment: .bottom) {
            Text(model.libraryRoot)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .confirmationDialog(
            "Remove Book?",
            isPresented: $showingRemovalDialog,
            titleVisibility: .visible,
            presenting: bookPendingRemoval
        ) { book in
            Button("Remove", role: .destructive) {
                removeBook(book)
            }
        } message: { book in
            Text("Remove \"\(book.title)\" and its notes from the library? The original EPUB file on disk is not touched.")
        }
        .onChange(of: model.selectedBookID) {
            Task { await model.loadSelectedBook() }
        }
    }

    private func requestRemoval(of book: BookSummary) {
        bookPendingRemoval = book
        showingRemovalDialog = true
    }

    private func removeBook(_ book: BookSummary) {
        Task { await model.removeBook(id: book.id) }
    }
}
