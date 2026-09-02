import SwiftUI
import MarginsModel

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @State private var showingError = false

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
        .alert("Something went wrong", isPresented: $showingError) {
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.activate() }
    }
}
