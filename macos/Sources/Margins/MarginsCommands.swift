import SwiftUI
import MarginsCore
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
        CommandMenu("Go") {
            Button("Next Chapter") {
                guard reader.isOpen, reader.nextChapter() != nil else { return }
                ReaderController.evaluateInReader(
                    "readerDisplay(\(ReaderController.javaScriptLiteral(reader.chapter?.href ?? "")))"
                )
            }
            Button("Previous Chapter") {
                guard reader.isOpen, reader.previousChapter() != nil else { return }
                ReaderController.evaluateInReader(
                    "readerDisplay(\(ReaderController.javaScriptLiteral(reader.chapter?.href ?? "")))"
                )
            }
            Divider()
            Button("Back to Library") {
                reader.close()
            }
        }
        CommandMenu("View") {
            Button("Toggle Notes") {
                reader.toggleNotes()
            }
            Divider()
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
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                model.requestHelp()
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }

    /// Same path as the `/` key: opens the note search overlay.
    private func find() async {
        model.requestSearch()
    }
}
