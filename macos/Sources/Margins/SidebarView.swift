import SwiftUI
import MarginsCore
import MarginsModel

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model
    @State private var showingRemovalDialog = false
    @State private var bookPendingRemoval: BookSummary?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: $model.selectedBookID) {
                ForEach(model.books) { book in
                    BookRowView(book: book)
                        .tag(book.id)
                        .onTapGesture(count: 2) {
                            Task { await model.openBookResuming(id: book.id) }
                        }
                        .contextMenu {
                            Button("Remove…", role: .destructive) {
                                requestRemoval(of: book)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            Divider()
            libraryRootBar
        }
        .navigationTitle("Library")
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

    /// Pinned under the list, outside the scroll content: the library root
    /// and the directory picker. Replaces the old floating overlay that sat
    /// on top of the last row.
    private var libraryRootBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.libraryRoot)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.libraryRoot)
            Spacer(minLength: 0)
            Button {
                Task { await RootPanel.run(model: model) }
            } label: {
                Image(systemName: "folder.badge.ellipsis")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose Library Directory…")
            .help("Choose Library Directory…")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func requestRemoval(of book: BookSummary) {
        bookPendingRemoval = book
        showingRemovalDialog = true
    }

    private func removeBook(_ book: BookSummary) {
        Task { await model.removeBook(id: book.id) }
    }
}
