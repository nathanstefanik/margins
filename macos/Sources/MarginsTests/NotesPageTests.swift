import Foundation
import Testing
import MarginsCore
import MarginsModel

@Suite("Notes page")
struct NotesPageTests {
    private func makeCompiledNotes(
        chaptersWithNotes: UInt32 = 3,
        chapterCount: UInt32 = 5,
        totalWords: UInt32 = 1240,
        lastUpdatedAt: String? = "2026-09-01T12:00:00+00:00"
    ) -> CompiledNotes {
        CompiledNotes(
            bookId: "book-1",
            bookTitle: "Test Book",
            bookAuthor: "Author",
            chapters: [],
            emptyChapters: [],
            chaptersWithNotes: chaptersWithNotes,
            chapterCount: chapterCount,
            totalWords: totalWords,
            firstCreatedAt: nil,
            lastUpdatedAt: lastUpdatedAt,
            suggestedFilename: "Author — Test Book — notes.md"
        )
    }

    @Test("stats line formats coverage, words, and last-updated date")
    func statsLineFormatting() {
        #expect(
            LibraryModel.statsLine(for: makeCompiledNotes())
                == "3/5 chapters annotated · 1,240 words · last updated Sep 1, 2026"
        )
    }

    @Test("stats line omits the date when the book was never updated")
    func statsLineWithoutDate() {
        let notes = makeCompiledNotes(
            chaptersWithNotes: 0,
            chapterCount: 2,
            totalWords: 0,
            lastUpdatedAt: nil
        )
        #expect(LibraryModel.statsLine(for: notes) == "0/2 chapters annotated · 0 words")
    }

    @Test("groupedCount separates thousands with a fixed comma")
    func groupedCount() {
        #expect(LibraryModel.groupedCount(0) == "0")
        #expect(LibraryModel.groupedCount(999) == "999")
        #expect(LibraryModel.groupedCount(1_000) == "1,000")
        #expect(LibraryModel.groupedCount(1_240) == "1,240")
        #expect(LibraryModel.groupedCount(12_345_678) == "12,345,678")
    }

    @Test("dateText renders a fixed-locale abbreviated date")
    func dateText() throws {
        let date = try #require(LibraryModel.parseRFC3339("2026-09-01T12:00:00+00:00"))
        #expect(LibraryModel.dateText(date) == "Sep 1, 2026")
    }

    @Test("loading compiled notes switches the detail mode; leaving resets it")
    @MainActor
    func detailModeSwitching() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        #expect(model.detailMode == .book)

        // Write two notes so the compilation has content.
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteBody = "first chapter summary words"
        await model.saveChapterNote(reader: reader)
        reader.nextChapter()
        reader.noteBody = "second chapter summary words"
        await model.saveChapterNote(reader: reader)

        let notes = try #require(await model.loadCompiledNotes(bookId: book.id))
        #expect(model.detailMode == .notes)
        #expect(model.compiledNotes?.bookId == book.id)
        #expect(notes.chaptersWithNotes == 2)
        #expect(notes.chapterCount == UInt32(book.chapters.count))
        #expect(notes.chapters.count == 2)
        #expect(notes.suggestedFilename.contains("notes.md"))
        #expect(!notes.suggestedFilename.isEmpty)

        // Re-selecting the same book keeps the notes page alive.
        await model.selectBook(id: book.id)
        #expect(model.detailMode == .notes)

        // Back to the book card.
        model.showBookDetail()
        #expect(model.detailMode == .book)

        // A cleared selection must not leave a stale notes page.
        await model.loadCompiledNotes(bookId: book.id)
        #expect(model.detailMode == .notes)
        await model.selectBook(id: nil)
        #expect(model.detailMode == .book)
        #expect(model.compiledNotes == nil)
    }

    @Test("the notes page survives a reload while the same book is selected")
    @MainActor
    func notesPageSurvivesReload() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)

        _ = await model.loadCompiledNotes(bookId: book.id)
        #expect(model.detailMode == .notes)

        // The detail card's refresh-on-appear and the sidebar's refresh()
        // both re-run loadSelectedBook; neither may discard the open page.
        await model.loadSelectedBook()
        #expect(model.detailMode == .notes)
        await model.refresh()
        #expect(model.detailMode == .notes)
        #expect(model.compiledNotes?.bookId == book.id)
    }
}
