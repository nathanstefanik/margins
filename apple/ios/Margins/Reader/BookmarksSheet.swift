import MarginsCore
import MarginsModel
import SwiftUI

/// Book-wide pins: drop from the reader chrome, manage here. Tap jumps;
/// swipe deletes; rename and restamp live on the row menu.
struct BookmarksSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader
    var onOpen: (Bookmark) -> Void = { _ in }
    var removalIDs: Set<String>? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: Bookmark?
    @State private var renameText = ""
    @State private var renameOpen = false

    private var listedBookmarks: [Bookmark] {
        guard let removalIDs else { return reader.bookmarks }
        return reader.bookmarks.filter { removalIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if reader.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No bookmarks yet",
                        systemImage: "bookmark",
                        description: Text("Bookmark this page from the reader chrome.")
                    )
                } else if removalIDs != nil {
                    List {
                        Section {
                            ForEach(listedBookmarks) { bookmark in
                                removalRow(bookmark)
                            }
                        } footer: {
                            Text(
                                "Several bookmarks are visible on this page. Choose the one to remove."
                            )
                        }
                    }
                } else {
                    List {
                        ForEach(reader.bookmarks) { bookmark in
                            bookmarkRow(bookmark)
                        }
                    }
                }
            }
            .navigationTitle(
                removalIDs == nil
                    ? BookmarkDisplay.countText(reader.bookmarks.count)
                    : "Remove Bookmark"
            )
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

    private func removalRow(_ bookmark: Bookmark) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(BookmarkDisplay.title(bookmark, chapters: reader.book?.chapters ?? []))
                    .font(.callout)
                Text(BookmarkDisplay.subtitle(bookmark, chapters: reader.book?.chapters ?? []))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: DesignTokens.Control.minimumTarget,
                alignment: .leading
            )
            Spacer(minLength: 8)
            Button("Remove", role: .destructive) {
                remove(bookmark)
            }
            .buttonStyle(.borderless)
        }
    }

    private func remove(_ bookmark: Bookmark) {
        guard let book = reader.book else { return }
        Task {
            await library.deleteBookmark(bookmark, bookId: book.id, reader: reader)
            if !reader.bookmarks.contains(where: { $0.id == bookmark.id }) {
                dismiss()
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
            .frame(
                maxWidth: .infinity,
                minHeight: DesignTokens.Control.minimumTarget,
                alignment: .leading
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
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
