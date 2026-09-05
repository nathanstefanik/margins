import AppKit
import UniformTypeIdentifiers
import MarginsModel

/// The shared ⌘O / `o` import flow. Multi-select is fine: each EPUB is
/// imported in turn with progress surfaced in the sidebar.
enum ImportPanel {
    @MainActor
    static func run(model: LibraryModel) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose EPUB files to add to the library."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await model.importEpubs(atPaths: panel.urls.map(\.path))
    }
}
