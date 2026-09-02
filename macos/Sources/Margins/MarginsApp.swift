import SwiftUI
import MarginsModel

@main
struct MarginsApp: App {
    @State private var model = LibraryModel()
    @State private var reader = ReaderModel()

    var body: some Scene {
        WindowGroup("Margins") {
            ContentView()
                .environment(model)
                .environment(reader)
        }
        .commands {
            MarginsCommands(model: model)
        }
    }
}
