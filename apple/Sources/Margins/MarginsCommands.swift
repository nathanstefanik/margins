import SwiftUI
import MarginsCore
import MarginsModel

struct MarginsCommands: Commands {
    let model: LibraryModel
    let clubs: ClubModel
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
            Button("Export Notes…") {
                Task { await exportNotes() }
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
        CommandMenu("Clubs") {
            Button("New Book Club…") {
                clubs.createSheetPresented = true
            }
            Button("Join Book Club…") {
                clubs.joinSheetPresented = true
            }
            .disabled(!clubs.supportsSharing)
            Divider()
            Button("Sync My Notes") {
                Task { await clubs.publishOwnSnapshot() }
            }
            .disabled(clubs.selectedClub == nil)
            Button("Export Club Notes…") {
                Task { await ClubExportPanel.run(model: clubs) }
            }
            .disabled(clubs.selectedClub == nil)
            Button("Copy Club Notes") {
                Task { await ClubExportPanel.copy(model: clubs) }
            }
            .disabled(clubs.selectedClub == nil)
        }
        CommandMenu("Go") {
            Button("Next Chapter") {
                guard reader.isOpen, reader.nextChapter() != nil else { return }
                ReaderController.evaluateInReader(
                    "readerDisplay(\(ReaderController.javaScriptLiteral(reader.displayTarget)))"
                )
            }
            Button("Previous Chapter") {
                guard reader.isOpen, reader.previousChapter() != nil else { return }
                ReaderController.evaluateInReader(
                    "readerDisplay(\(ReaderController.javaScriptLiteral(reader.displayTarget)))"
                )
            }
            Divider()
            Button("Back to Library") {
                reader.close()
            }
        }
        CommandMenu("View") {
            Button("Book Notes") {
                Task { await showNotesPage() }
            }
            .keyboardShortcut("N", modifiers: .command)
            Divider()
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

    /// View → Book Notes (⇧⌘N): closes any reading session and shows the
    /// selected book's compiled notes page.
    private func showNotesPage() async {
        guard let id = model.selectedBookID else { return }
        if reader.isOpen {
            reader.close()
        }
        await model.loadCompiledNotes(bookId: id)
    }

    /// File → Export Notes…: loads (or reuses) the compiled notes for the
    /// selected book, then runs the save panel.
    private func exportNotes() async {
        guard let id = model.selectedBookID else { return }
        if reader.isOpen {
            reader.close()
        }
        let notes = model.compiledNotes?.bookId == id
            ? model.compiledNotes
            : await model.loadCompiledNotes(bookId: id)
        guard let notes else { return }
        await ExportNotesPanel.run(model: model, notes: notes)
    }
}
