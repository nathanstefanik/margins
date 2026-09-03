import Foundation
import Testing
import MarginsCore
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

    @Test("placeholder initials and tint index are deterministic")
    func placeholderVisualsAreDeterministic() {
        #expect(BookCoverPlaceholder.initials(for: "The Brothers Karamazov") == "TB")
        #expect(BookCoverPlaceholder.initials(for: "moby dick") == "MD")
        #expect(BookCoverPlaceholder.initials(for: "Dune") == "D")
        #expect(BookCoverPlaceholder.initials(for: "") == "")

        let paletteSize = 8
        for title in ["Dune", "1984", "A Brief History of Time", "Капитанская дочка", ""] {
            let first = BookCoverPlaceholder.tintIndex(for: title, paletteSize: paletteSize)
            let second = BookCoverPlaceholder.tintIndex(for: title, paletteSize: paletteSize)
            #expect(first == second, "tint must not depend on process state")
            #expect(first >= 0 && first < paletteSize)
        }
    }

    @Test("annotated chapter rows follow the spine and join note stats")
    func annotatedChapterRowsFollowSpineOrder() {
        let chapters = [
            ChapterMeta(key: "001", index: 0, title: "One", href: "one.xhtml"),
            ChapterMeta(key: "002", index: 1, title: "Two", href: "two.xhtml"),
            ChapterMeta(key: "003", index: 2, title: "Three", href: "three.xhtml"),
        ]
        // Index order must not matter: the spine defines the row order.
        let index = [
            NoteIndexEntry(chapterKey: "003", chapterIndex: 2, chapterTitle: "Three", wordCount: 41, updatedAt: nil),
            NoteIndexEntry(chapterKey: "001", chapterIndex: 0, chapterTitle: "One", wordCount: 98, updatedAt: "2026-09-01T12:00:00+00:00"),
        ]

        let rows = LibraryModel.annotatedChapterRows(chapters: chapters, index: index)

        #expect(rows.map(\.chapter.key) == ["001", "003"])
        #expect(rows[0].wordCount == 98)
        #expect(rows[0].updatedAt == "2026-09-01T12:00:00+00:00")
        #expect(rows[1].wordCount == 41)
    }

    @Test("chapter → note word count join from the notes index")
    @MainActor
    func chapterNoteWordCountJoin() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteBody = "one two three four"
        await model.saveChapterNote(reader: reader)
        #expect(reader.notesError == nil)

        // Reloading the book (as the detail view does on selection) brings
        // the notes index along; the join then flags only chapter one.
        await model.loadSelectedBook()
        let counts = LibraryModel.noteWordCounts(
            chapters: book.chapters,
            index: model.selectedBookNotesIndex
        )
        #expect(counts[book.chapters[0].key] == 4)
        #expect(counts.count == 1)
        #expect(counts[book.chapters[1].key] == nil)
    }
}
