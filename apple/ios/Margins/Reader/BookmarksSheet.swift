import SwiftUI
import MarginsCore
import MarginsModel

/// Book-wide pins: drop from the reader chrome, manage here. Tap jumps;
/// swipe deletes; rename and restamp live on the row menu.
struct BookmarksSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader
    var onOpen: (Bookmark) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Bookmark?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if reader.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No bookmarks yet",
                        systemImage: "bookmark",
                        description: Text("Bookmark this page from the reader chrome.")
                    )
                } else {
                    List {
                        ForEach(reader.bookmarks) { bookmark in
                            bookmarkRow(bookmark)
                        }
                    }
                }
            }
            .navigationTitle(BookmarkDisplay.countText(reader.bookmarks.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Name", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        Button {
            onOpen(bookmark)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(BookmarkDisplay.title(bookmark, chapters: reader.book?.chapters ?? []))
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(BookmarkDisplay.subtitle(bookmark, chapters: reader.book?.chapters ?? []))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .accessibilityHint("Opens this bookmark in the reader")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", role: .destructive) {
                delete(bookmark)
            }
        }
        .contextMenu {
            Button("Rename") {
                renameText = bookmark.label
                renaming = bookmark
            }
            Button("Update to Here") {
                updateToHere(bookmark)
            }
            Button("Delete", role: .destructive) {
                delete(bookmark)
            }
        }
    }

    private func saveRename() {
        guard let bookmark = renaming, let book = reader.book else { return }
        renaming = nil
        Task {
            await library.updateBookmark(
                bookmark, bookId: book.id, label: renameText, reader: reader
            )
        }
    }

    private func updateToHere(_ bookmark: Bookmark) {
        guard let book = reader.book, let position = reader.currentPosition() else { return }
        Task {
            await library.updateBookmark(
                bookmark, bookId: book.id, position: position, reader: reader
            )
        }
    }

    private func delete(_ bookmark: Bookmark) {
        guard let book = reader.book else { return }
        Task {
            await library.deleteBookmark(bookmark, bookId: book.id, reader: reader)
        }
    }
}
