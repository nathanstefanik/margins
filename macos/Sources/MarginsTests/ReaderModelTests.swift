import Testing
import Foundation
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
            coverPath: nil,
            progressPercent: nil
        )
    }

    @Test("relocated records clamped page progress")
    func relocatedRecordsProgress() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])

        reader.relocated(page: 3, totalPages: 12, href: nil, cfi: nil)
        #expect(reader.progress == ReaderProgress(page: 3, totalPages: 12))

        // Below and above the valid range clamp into it.
        reader.relocated(page: -2, totalPages: 0, href: nil, cfi: nil)
        #expect(reader.progress == ReaderProgress(page: 1, totalPages: 0))
        reader.relocated(page: 40, totalPages: 12, href: nil, cfi: nil)
        #expect(reader.progress == ReaderProgress(page: 12, totalPages: 12))
    }

    @Test("relocated follows the chapter across section boundaries")
    func relocatedFollowsChapter() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])

        reader.relocated(page: 1, totalPages: 8, href: "two.xhtml", cfi: nil)
        #expect(reader.chapter?.key == "ch2")

        // An href that doesn't match a known chapter keeps the current one.
        reader.relocated(page: 2, totalPages: 8, href: "missing.xhtml", cfi: nil)
        #expect(reader.chapter?.key == "ch2")
        #expect(reader.progress == ReaderProgress(page: 2, totalPages: 8))
    }

    @Test("open and clear progress")
    func openAndCloseResetProgress() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(page: 2, totalPages: 9, href: nil, cfi: nil)
        #expect(reader.progress != nil)

        reader.open(book: book, chapter: book.chapters[1])
        #expect(reader.progress == nil)

        reader.relocated(page: 1, totalPages: 5, href: nil, cfi: nil)
        reader.close()
        #expect(reader.progress == nil)
    }

    @Test("book percent interpolates the chapter index and clamps")
    func bookPercentInterpolates() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])

        // Start of a two-chapter book: on page 1 of 10 → 5% of the book.
        reader.relocated(page: 1, totalPages: 10, href: nil, cfi: nil)
        #expect(abs(reader.bookPercent! - 5.0) < 0.001)

        // Midway through the first chapter's pages.
        reader.relocated(page: 6, totalPages: 10, href: nil, cfi: nil)
        #expect(abs(reader.bookPercent! - 30.0) < 0.001)

        // Last page of the last chapter reaches exactly 100.
        reader.open(book: book, chapter: book.chapters[1])
        reader.relocated(page: 10, totalPages: 10, href: nil, cfi: nil)
        #expect(reader.bookPercent == 100)

        // Closed reader has no percent.
        reader.close()
        #expect(reader.bookPercent == nil)
    }

    private final class SaveSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [(String, ReadingPosition)] = []

        func record(_ bookId: String, _ position: ReadingPosition) {
            lock.lock()
            saved.append((bookId, position))
            lock.unlock()
        }

        var all: [(String, ReadingPosition)] {
            lock.lock()
            defer { lock.unlock() }
            return saved
        }
    }

    @Test("position saves debounce to one latest-wins write")
    func positionSavesDebounce() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        reader.positionSaveDebounce = 0.02
        reader.positionSaver = { bookId, position in
            spy.record(bookId, position)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(page: 1, totalPages: 10, href: "one.xhtml", cfi: "cfi-1")
        reader.relocated(page: 2, totalPages: 10, href: "one.xhtml", cfi: "cfi-2")
        reader.relocated(page: 3, totalPages: 10, href: "one.xhtml", cfi: "cfi-3")

        try await Task.sleep(for: .milliseconds(250))
        let saved = spy.all
        #expect(saved.count == 1)
        #expect(saved.first?.0 == book.id)
        #expect(saved.first?.1.epubCfi == "cfi-3")
        #expect(saved.first?.1.chapterKey == "ch1")
        #expect(saved.first!.1.percent >= 0 && saved.first!.1.percent <= 100)
    }

    @Test("closing the reader flushes the pending position save")
    func closeFlushesPositionSave() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        // Debounce longer than the test wait: only the close-flush can save.
        reader.positionSaveDebounce = 10
        reader.positionSaver = { bookId, position in
            spy.record(bookId, position)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[1])
        reader.relocated(page: 4, totalPages: 10, href: "two.xhtml", cfi: "cfi-late")
        reader.close()

        try await Task.sleep(for: .milliseconds(100))
        let saved = spy.all
        #expect(saved.count == 1)
        #expect(saved.first?.1.chapterKey == "ch2")
        #expect(saved.first?.1.epubCfi == "cfi-late")
    }
}
