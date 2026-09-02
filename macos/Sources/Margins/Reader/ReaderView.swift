import SwiftUI
import MarginsModel

struct ReaderView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader

    var body: some View {
        HSplitView {
            ReaderWebView(model: model, reader: reader)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            if reader.notesVisible {
                NotesPane()
            }
        }
        .navigationTitle(reader.book?.title ?? "Reader")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Library", systemImage: "sidebar.left", action: reader.close)
            }
            ToolbarItem(placement: .navigation) {
                Button("Notes", systemImage: "square.and.pencil") {
                    reader.toggleNotes()
                }
            }
        }
    }
}
