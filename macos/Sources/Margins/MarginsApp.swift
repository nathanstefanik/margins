import SwiftUI
import MarginsModel

@main
struct MarginsApp: App {
    @State private var model = LibraryModel()
    @State private var reader = ReaderModel()

    init() {
        model.reader = reader
        reader.positionSaver = { [weak model] bookId, position in
            await model?.saveReadingPosition(bookId: bookId, position: position)
        }
        reader.noteSaver = { [weak model] bookId, chapterKey, body in
            await model?.saveChapterNoteText(bookId: bookId, chapterKey: chapterKey, body: body)
        }
    }

    var body: some Scene {
        WindowGroup("Margins") {
            ContentView()
                .environment(model)
                .environment(reader)
        }
        .commands {
            MarginsCommands(model: model, reader: reader)
        }
        Settings {
            Text("Nothing to configure yet.")
                .frame(minWidth: 280, minHeight: 120)
        }
    }
}
