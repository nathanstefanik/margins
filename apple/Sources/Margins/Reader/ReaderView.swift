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
