import SwiftUI
import MarginsModel

struct ReaderView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @State private var typographyOpen = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ReaderWebView(model: model, reader: reader)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                ReaderFooter(reader: reader)
            }
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
