import SwiftUI
import MarginsModel

@main
struct MarginsApp: App {
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup("Margins") {
            ContentView()
                .environment(model)
        }
        .commands {
            MarginsCommands(model: model)
        }
    }
}
