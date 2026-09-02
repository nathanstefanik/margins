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
            Button("Choose Library Directory…") {
                Task { await RootPanel.run(model: model) }
            }
            Divider()
            Button("Find") {
                Task { await find() }
            }
            .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Save Note") {
                reader.flushNoteSave()
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        CommandMenu("View") {
            Button("Bigger Text") {
                reader.preferences.stepFontSize(ReaderPreferences.fontSizeStep)
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") {
                reader.preferences.stepFontSize(-ReaderPreferences.fontSizeStep)
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Reset Text Size") {
                reader.preferences.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// Same path as the `/` key: opens the note search overlay.
    private func find() async {
        model.requestSearch()
    }
}
