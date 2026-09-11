import AppKit
import MarginsModel

/// The shared library-directory picker (sidebar folder button and the File
/// menu item).
enum RootPanel {
    @MainActor
    static func run(model: LibraryModel) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the directory that holds your library. Books and notes move with it."
        panel.prompt = "Use Directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LibraryRootBookmark.remember(url)
        await model.setLibraryRoot(url.path)
    }
}
