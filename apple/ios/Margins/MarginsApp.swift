import SwiftUI
import MarginsModel

@main
struct MarginsApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryScene()
                .environment(app.library)
                .environment(app.reader)
                .environment(app)
                .task { await app.activate() }
        }
    }
}
