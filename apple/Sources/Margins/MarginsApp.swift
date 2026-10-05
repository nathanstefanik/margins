import MarginsModel
import SwiftUI

@main
struct MarginsApp: App {
    @State private var model = LibraryModel()
    @State private var clubs = ClubModel()
    @State private var reader = ReaderModel()

    init() {
        LibraryRootBookmark.restore()
    }

    /// Cross-wires the installed models: the reader's savers land in the
    /// library, the library drives the reader, and search gets its
    /// executor. Called from `ContentView`'s `.task`, which sees the live
    /// `@State` instances — `init()` reads pre-install preview objects that
    /// the scene discards, so wiring done there binds to dead models.
    static func wireModels(model: LibraryModel, reader: ReaderModel) {
        model.reader = reader
        reader.positionSaver = { [weak model] bookId, position in
            await model?.saveReadingPosition(bookId: bookId, position: position)
        }
        reader.noteSaver = { [weak model] bookId, chapterKey, body in
            await model?.saveChapterNoteText(bookId: bookId, chapterKey: chapterKey, body: body)
        }
        model.search.setExecutor { [weak model] text in
            // macOS has no notebooks UI yet — drop notebook hits rather
            // than showing rows that lead nowhere.
            await (model?.searchNotes(text) ?? []).filter { $0.kind != .notebook }
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
