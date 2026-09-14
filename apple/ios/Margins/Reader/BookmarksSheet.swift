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
    @State private var renameTarget: Bookmark?
    @State private var renameText = ""
    @State private var renameOpen = false

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
            .alert("Name", isPresented: $renameOpen) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    guard let bookmark = renameTarget, let book = reader.book else { return }
                    let text = renameText
                    Task {
                        await library.updateBookmark(
                            bookmark, bookId: book.id, label: text, reader: reader
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
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
        .onTapGesture { onOpen(bookmark) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this bookmark in the reader")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", role: .destructive) {
                delete(bookmark)
            }
        }
        .contextMenu {
            Button("Rename") {
                renameTarget = bookmark
                renameText = bookmark.label
                renameOpen = true
            }
            Button("Update to Here") {
                updateToHere(bookmark)
            }
            Button("Delete", role: .destructive) {
                delete(bookmark)
            }
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
