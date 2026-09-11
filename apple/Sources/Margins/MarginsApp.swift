import SwiftUI
import MarginsModel

@main
struct MarginsApp: App {
    @State private var model = LibraryModel()
    @State private var clubs = ClubModel()
    @State private var reader = ReaderModel()

    init() {
        LibraryRootBookmark.restore()
        model.reader = reader
        reader.positionSaver = { [weak model] bookId, position in
            await model?.saveReadingPosition(bookId: bookId, position: position)
        }
        reader.noteSaver = { [weak model] bookId, chapterKey, body in
            await model?.saveChapterNoteText(bookId: bookId, chapterKey: chapterKey, body: body)
        }
        model.search.setExecutor { [weak model] text in
            await model?.searchNotes(text) ?? []
        }
    }

    var body: some Scene {
        WindowGroup("Margins") {
            ContentView()
                .environment(model)
                .environment(clubs)
                .environment(reader)
        }
        .commands {
            MarginsCommands(model: model, clubs: clubs, reader: reader)
        }
        Settings {
            SettingsView(model: model, clubs: clubs, reader: reader)
        }
    }
}
