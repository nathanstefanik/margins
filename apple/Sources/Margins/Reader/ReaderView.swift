import SwiftUI
import MarginsModel

struct ReaderView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @State private var typographyOpen = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ReaderWebView(model: model, reader: reader)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                ReaderFooter(reader: reader)
            }
            .background(Paper.background(reader.preferences.theme))
            .frame(maxWidth: .infinity)
            if reader.notesVisible {
                NotesPane()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: reader.notesVisible)
        .navigationTitle(reader.book?.title ?? "Reader")
        .task(id: reader.book?.id) {
            await model.loadBookmarks(reader: reader)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Library", systemImage: "sidebar.left", action: reader.close)
            }
            ToolbarItem(placement: .navigation) {
                Button("Notes", systemImage: "square.and.pencil") {
                    reader.toggleNotes()
                }
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    guard let book = reader.book, let position = reader.currentPosition() else { return }
                    Task {
                        await model.addBookmark(bookId: book.id, position: position, reader: reader)
                    }
                } label: {
                    Label(
                        "Bookmark This Page",
                        systemImage: reader.pageIsBookmarked ? "bookmark.fill" : "bookmark"
                    )
                }
                .help("Bookmark this page (b). Press B for the list.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    typographyOpen.toggle()
                } label: {
                    Label("Typography", systemImage: "textformat")
                }
                .popover(isPresented: $typographyOpen, arrowEdge: .bottom) {
                    TypographyPopover(preferences: reader.preferences)
                }
            }
        }
    }
}
