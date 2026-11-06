import MarginsModel
import SwiftUI

@main
struct MarginsApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The bundled Easy face (Atkinson Hyperlegible Next) must be
        // registered with Core Text before reader chrome asks for it.
        ReaderFonts.registerBundled()
    }

    var body: some Scene {
        WindowGroup {
            LibraryScene()
                .environment(app.library)
                .environment(app.reader)
                .environment(app.clubs)
                .environment(app.notebooks)
                .environment(app.search)
                .environment(app)
                .task { await app.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        app.scheduleSync()
                    } else if phase == .background {
                        Task { await app.syncInBackground() }
                    }
                }
                .onChange(of: app.connectivity.isOnline) { wasOnline, isOnline in
                    if !wasOnline, isOnline {
                        app.scheduleSync()
                    }
                }
                .onOpenURL { url in
                    // "Open in Margins" from Files/Mail: the URL is a
                    // security-scoped EPUB; import a copy into the library.
                    Task { await app.importSecurityScoped(url) }
                }
        }
    }
}
