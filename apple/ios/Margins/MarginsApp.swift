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
                .onOpenURL { url in
                    // "Open in Margins" from Files/Mail: the URL is a
                    // security-scoped EPUB; import a copy into the library.
                    Task { await app.importSecurityScoped(url) }
                }
        }
    }
}
