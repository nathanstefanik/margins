import SwiftUI
import MarginsCore
import MarginsModel

/// In-window list of named location pins for the open book. Same scrim
/// pattern as search and the cheat sheet; Esc (via the shell monitor)
/// dismisses. Click a row to jump; rename, restamp, and delete sit on
/// the row.
struct BookmarksOverlay: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader

    @State private var renaming: Bookmark?
    @State private var renameText = ""

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.requestBookmarksDismissal() }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Bookmarks")
                        .font(.title3)
                    Spacer()
                    Text("esc")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                }
                .padding(18)

                Divider()

                if reader.bookmarks.isEmpty {
                    Text("No bookmarks yet — press b to pin this page.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(reader.bookmarks) { bookmark in
                                bookmarkRow(bookmark)
                                if bookmark.id != reader.bookmarks.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 420)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .frame(width: 480)
            .padding(.top, 40)
            .contentShape(.rect)
            .onTapGesture {}
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

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        let chapters = reader.book?.chapters ?? []
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                jump(bookmark)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BookmarkDisplay.title(bookmark, chapters: chapters))
                        .font(.callout)
                    Text(BookmarkDisplay.subtitle(bookmark, chapters: chapters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Rename") {
                renameText = bookmark.label
                renaming = bookmark
            }
            .buttonStyle(.borderless)
            Button("Update") {
                updateToHere(bookmark)
            }
            .buttonStyle(.borderless)
            .help("Move this bookmark to the current page")
            Button("Delete", role: .destructive) {
                delete(bookmark)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func jump(_ bookmark: Bookmark) {
        guard let book = reader.book else { return }
        model.requestBookmarksDismissal()
        Task {
            await model.openPassage(
                bookId: book.id,
                chapterKey: bookmark.chapterKey,
                cfi: bookmark.epubCfi
            )
        }
    }

    private func saveRename() {
        guard let bookmark = renaming, let book = reader.book else { return }
        renaming = nil
        Task {
            await model.updateBookmark(
                bookmark, bookId: book.id, label: renameText, reader: reader
            )
        }
    }

    private func updateToHere(_ bookmark: Bookmark) {
        guard let book = reader.book, let position = reader.currentPosition() else { return }
        Task {
            await model.updateBookmark(
                bookmark, bookId: book.id, position: position, reader: reader
            )
        }
    }

    private func delete(_ bookmark: Bookmark) {
        guard let book = reader.book else { return }
        Task {
            await model.deleteBookmark(bookmark, bookId: book.id, reader: reader)
        }
    }
}
