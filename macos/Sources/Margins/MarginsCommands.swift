import SwiftUI
import MarginsModel

struct MarginsCommands: Commands {
    let model: LibraryModel
    let reader: ReaderModel

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
            Divider()
            Button("Save Note") {
                Task { await model.saveChapterNote(reader: reader) }
            }
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    /// Same path as the `/` key: opens the note search overlay.
    private func find() async {
        model.requestSearch()
    }
}
