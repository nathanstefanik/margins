import SwiftUI
import MarginsModel

@main
struct MarginsApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryScene()
                .environment(app.library)
                .environment(app.reader)
                .environment(app.clubs)
                .environment(app)
                .task { await app.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await app.downloadPass() }
                    }
                }
                .onChange(of: app.connectivity.isOnline) { wasOnline, isOnline in
                    if !wasOnline, isOnline {
                        Task { await app.downloadPass() }
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
