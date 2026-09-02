import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MarginsModel

struct MarginsCommands: Commands {
    let model: LibraryModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import EPUB…") {
                Task { await runImportPanel() }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }

    @MainActor
    private func runImportPanel() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB file to add to the library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await model.importEpub(atPath: url.path)
    }
}
