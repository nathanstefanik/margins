import AppKit
import UniformTypeIdentifiers
import MarginsModel

/// The shared ⌘O / `o` import flow.
enum ImportPanel {
    @MainActor
    static func run(model: LibraryModel) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB file to add to the library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await model.importEpub(atPath: url.path)
    }
}
