import Foundation
import Testing
import MarginsModel

@Suite("Library model")
struct LibraryModelTests {
    @Test("activate starts with an empty library and a resolved root")
    @MainActor
    func activateStartsEmpty() async throws {
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(model.books.isEmpty)
        #expect(!model.libraryRoot.isEmpty)
        #expect(model.selectedBookID == nil)
        #expect(model.selectedBook == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("import → selection → chapters through the model")
    @MainActor
    func importSelectsAndLoadsChapters() async throws {
        let fixtures = try fixtureEpubs()
        #expect(!fixtures.isEmpty, "expected at least one fixtures/*.epub")

        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()

        for fixture in fixtures {
            let imported = await model.importEpub(atPath: fixture)
            #expect(imported, "import failed: \(model.errorMessage ?? "no error")")
            #expect(model.errorMessage == nil)

            // The import refreshed the list and selected the new book.
            #expect(model.books.count == 1)
            #expect(model.selectedBookID != nil)

            let book = try #require(model.selectedBook)
            #expect(book.id == model.selectedBookID)
            #expect(!book.title.isEmpty)
            #expect(!book.author.isEmpty)
            #expect(!book.chapters.isEmpty)

            // Chapter count in the detail view agrees with the list summary.
            #expect(model.books.first?.chapterCount == UInt32(book.chapters.count))
        }
    }

    @Test("remove clears selection and empties the library")
    @MainActor
    func removeBookClearsSelection() async throws {
        let fixtures = try fixtureEpubs()
        let fixture = try #require(fixtures.first)

        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()

        let imported = await model.importEpub(atPath: fixture)
        #expect(imported)
        let id = try #require(model.selectedBookID)

        await model.removeBook(id: id)

        #expect(model.books.isEmpty)
        #expect(model.selectedBookID == nil)
        #expect(model.selectedBook == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("import failure surfaces an error message")
    @MainActor
    func importFailureSurfacesError() async throws {
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()

        let missing = URL(fileURLWithPath: try makeTempDataDir())
            .appendingPathComponent("does-not-exist.epub").path
        let imported = await model.importEpub(atPath: missing)

        #expect(!imported)
        #expect(model.errorMessage != nil)
        #expect(model.books.isEmpty)

        model.clearError()
        #expect(model.errorMessage == nil)
    }
}
