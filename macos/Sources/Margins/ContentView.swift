import SwiftUI
import MarginsModel

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @State private var showingError = false
    @State private var showSearch = false
    @State private var keyboardController: ShellKeyboardController?

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailArea()
        }
        .frame(minWidth: 720, minHeight: 440)
        .onChange(of: model.errorMessage) {
            showingError = model.errorMessage != nil
        }
        .onChange(of: model.searchRequest) {
            showSearch = true
        }
        .alert("Something went wrong", isPresented: $showingError) {
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet()
        }
        .task { await model.activate() }
        .onAppear {
            if keyboardController == nil {
                let controller = ShellKeyboardController(model: model, reader: reader)
                controller.start()
                keyboardController = controller
            }
        }
    }
}
