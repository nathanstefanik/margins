import SwiftUI
import MarginsModel

struct ReaderView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader

    var body: some View {
        ReaderWebView(model: model, reader: reader)
            .navigationTitle(reader.book?.title ?? "Reader")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Library", systemImage: "sidebar.left", action: reader.close)
                }
            }
    }
}
