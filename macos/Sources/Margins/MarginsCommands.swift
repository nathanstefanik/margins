import SwiftUI
import MarginsModel

struct MarginsCommands: Commands {
    let model: LibraryModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import EPUB…") {
                Task { await ImportPanel.run(model: model) }
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("Find") {
                Task { await find() }
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    /// Routed through the `/` action; the search UI lands in Part III.
    private func find() async {}
}
