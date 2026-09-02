import Testing
import MarginsCore
import MarginsModel

@Suite("ReaderModel")
@MainActor
struct ReaderModelTests {
    private func makeBook() -> BookMeta {
        BookMeta(
            id: "book-1",
            title: "Test Book",
            author: "Author",
            language: "en",
            addedAt: "2026-01-01",
            sourceFilename: "test.epub",
            chapters: [
                ChapterMeta(key: "ch1", index: 0, title: "One", href: "one.xhtml"),
                ChapterMeta(key: "ch2", index: 1, title: "Two", href: "two.xhtml"),
            ],
            coverPath: nil
        )
    }

    @Test("relocated records clamped page progress")
    func relocatedRecordsProgress() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])

        reader.relocated(page: 3, totalPages: 12, href: nil)
        #expect(reader.progress == ReaderProgress(page: 3, totalPages: 12))

        // Below and above the valid range clamp into it.
        reader.relocated(page: -2, totalPages: 0, href: nil)
        #expect(reader.progress == ReaderProgress(page: 1, totalPages: 0))
        reader.relocated(page: 40, totalPages: 12, href: nil)
        #expect(reader.progress == ReaderProgress(page: 12, totalPages: 12))
    }

    @Test("relocated follows the chapter across section boundaries")
    func relocatedFollowsChapter() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])

        reader.relocated(page: 1, totalPages: 8, href: "two.xhtml")
        #expect(reader.chapter?.key == "ch2")

        // An href that doesn't match a known chapter keeps the current one.
        reader.relocated(page: 2, totalPages: 8, href: "missing.xhtml")
        #expect(reader.chapter?.key == "ch2")
        #expect(reader.progress == ReaderProgress(page: 2, totalPages: 8))
    }

    @Test("open and clear progress")
    func openAndCloseResetProgress() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(page: 2, totalPages: 9, href: nil)
        #expect(reader.progress != nil)

        reader.open(book: book, chapter: book.chapters[1])
        #expect(reader.progress == nil)

        reader.relocated(page: 1, totalPages: 5, href: nil)
        reader.close()
        #expect(reader.progress == nil)
    }
}
