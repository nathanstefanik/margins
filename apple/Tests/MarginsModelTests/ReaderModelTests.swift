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
            addedAt: Date(timeIntervalSince1970: 1_767_225_600), // 2026-01-01T00:00:00Z
            sourceFilename: "test.epub",
            chapters: [
                ChapterMeta(key: "ch1", index: 0, title: "One", href: "one.xhtml", fragment: nil),
                ChapterMeta(key: "ch2", index: 1, title: "Two", href: "two.xhtml", fragment: "part-two"),
            ],
            coverPath: nil,
            progressPercent: nil
        )
    }

    @Test("jumpTarget appends the TOC anchor only when the book named one")
    func jumpTargetUsesTheFragment() {
        let book = makeBook()
        // No TOC entry for the file: the top of the file is the chapter.
        #expect(book.chapters[0].jumpTarget == "one.xhtml")        // With one, the jump carries the anchor so a file holding several
        // chapters still lands on the right heading.
        #expect(book.chapters[1].jumpTarget == "two.xhtml#part-two")
    }

    @Test("jumpTarget ignores an empty fragment")
    func jumpTargetIgnoresEmptyFragment() {
        let chapter = ChapterMeta(key: "ch3", index: 2, title: "Three", href: "three.xhtml", fragment: "")
        #expect(chapter.jumpTarget == "three.xhtml")
    }

    @Test("displayTarget honors an outline section fragment and resets across chapters")
    func displayTargetUsesSectionFragment() {
        let reader = ReaderModel()
        let book = makeBook()

        // An outline row inside a multi-section file opens at its own anchor.
        reader.open(book: book, chapter: book.chapters[1], fragment: "section-2")
        #expect(reader.displayTarget == "two.xhtml#section-2")

        // Following the renderer into another chapter clears the override and
        // falls back to that chapter's own anchor.
        reader.relocated(page: 1, totalPages: 2, href: "one.xhtml", cfi: nil)
        #expect(reader.chapter?.key == "ch1")
        #expect(reader.displayTarget == "one.xhtml")

        // An explicit open without a fragment uses the chapter's own anchor.
        reader.open(book: book, chapter: book.chapters[1])
        #expect(reader.displayTarget == "two.xhtml#part-two")
    }

    @Test("relocated still matches chapters by bare href")
    func relocatedMatchesBareHref() {
        // Relocation events carry the section href without a fragment, so a
        // chapter that jumps to an anchor must still be found by `href`.
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(page: 1, totalPages: 4, href: "two.xhtml", cfi: nil)
        #expect(reader.chapter?.key == "ch2")
    }

    @Test("finishedChapter accepts only the immediate successor after a last page")
    func finishedChapterPredicate() {
        let book = makeBook()
        let chapters = book.chapters
        let lastPageOfOne = ReaderProgress(page: 4, totalPages: 4)
        let midOne = ReaderProgress(page: 2, totalPages: 4)

        // Paging past chapter one's last page onto chapter two: finished.
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "ch1", previousProgress: lastPageOfOne,
                newKey: "ch2", newProgress: ReaderProgress(page: 1, totalPages: 9),
                chapters: chapters
            )?.key == "ch1"
        )

        // Jumping from a last page to a much later chapter (TOC): not
        // "finishing" the chapter in between.
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "ch1", previousProgress: lastPageOfOne,
                newKey: "nonexistent", newProgress: ReaderProgress(page: 1, totalPages: 9),
                chapters: chapters
            ) == nil
        )

        // Still on the same chapter.
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "ch1", previousProgress: lastPageOfOne,
                newKey: "ch1", newProgress: lastPageOfOne,
                chapters: chapters
            ) == nil
        )

        // Not on the previous chapter's last page.
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "ch1", previousProgress: midOne,
                newKey: "ch2", newProgress: ReaderProgress(page: 1, totalPages: 9),
                chapters: chapters
            ) == nil
        )

        // No page counts (rendition not settled).
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "ch1", previousProgress: ReaderProgress(page: 4, totalPages: 0),
                newKey: "ch2", newProgress: ReaderProgress(page: 1, totalPages: 9),
                chapters: chapters
            ) == nil
        )

        // No new progress yet (rendition not live for the new chapter).
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "ch1", previousProgress: lastPageOfOne,
                newKey: "ch2", newProgress: nil,
                chapters: chapters
            ) == nil
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

    @Test("open signals a retarget; relocated chapter drift does not")
    func openGenerationTracksExternalNavigations() {
        let reader = ReaderModel()
        let book = makeBook()
        #expect(reader.openGeneration == 0)

        reader.open(book: book, chapter: book.chapters[0])
        #expect(reader.openGeneration == 1)

        // The renderer moving across a section boundary is already on
        // screen; it must not ask the webview to reload.
        reader.relocated(page: 1, totalPages: 4, href: "two.xhtml", cfi: nil)
        #expect(reader.chapter?.key == "ch2")
        #expect(reader.openGeneration == 1)

        reader.open(book: book, chapter: book.chapters[1])
        #expect(reader.openGeneration == 2)
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

    @Test("progress and succession follow the filtered chapter list, not raw spine indexes")
    func filteredSpinePositions() {
        // "002" was `linear="no"`, so the raw indexes skip: 0, 2. A percent
        // keyed on the raw index would reach 125% here.
        let book = BookMeta(
            id: "book-2", title: "Gappy", author: "Author",
            addedAt: Date(timeIntervalSince1970: 0), sourceFilename: "gappy.epub",
            chapters: [
                ChapterMeta(key: "001", index: 0, title: "One", href: "one.xhtml"),
                ChapterMeta(key: "003", index: 2, title: "Three", href: "three.xhtml"),
            ]
        )
        let reader = ReaderModel()
        reader.open(book: book, chapter: book.chapters[1])
        reader.relocated(page: 5, totalPages: 10, href: nil, cfi: nil)
        // Position 1 of 2, halfway through: 75%.
        #expect(abs(reader.bookPercent! - 75.0) < 0.001)

        // The second listed chapter is the first one's immediate successor
        // even though its raw index skipped a number.
        #expect(
            ReaderModel.finishedChapter(
                previousKey: "001", previousProgress: ReaderProgress(page: 4, totalPages: 4),
                newKey: "003", newProgress: ReaderProgress(page: 1, totalPages: 9),
                chapters: book.chapters
            )?.key == "001"
        )
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

    /// Waits for the debounced save to land, then lets a full debounce
    /// window pass so a collapse bug (extra saves) can still surface. The
    /// wait is a poll with a generous timeout, not a fixed sleep: parallel
    /// test load can starve the debounced task past any fixed window.
    private func settle(
        until condition: () -> Bool,
        quietPeriod: Duration = .milliseconds(250),
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: quietPeriod)
    }

    @Test("position saves debounce to one latest-wins write")
    func positionSavesDebounce() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        // Collapse the debounce window: three synchronous relocations still
        // cancel each other down to one save, but the test no longer depends
        // on a real timer firing under CI scheduling load.
        reader.debounceSleep = { _ in }
        reader.positionSaver = { bookId, position in
            spy.record(bookId, position)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(page: 1, totalPages: 10, href: "one.xhtml", cfi: "cfi-1")
        reader.relocated(page: 2, totalPages: 10, href: "one.xhtml", cfi: "cfi-2")
        reader.relocated(page: 3, totalPages: 10, href: "one.xhtml", cfi: "cfi-3")

        try await settle { !spy.all.isEmpty }
        let saved = spy.all
        #expect(saved.count == 1)
        #expect(saved.first?.0 == book.id)
        #expect(saved.first?.1.epubCfi == "cfi-3")
        #expect(saved.first?.1.chapterKey == "ch1")
        #expect(
            saved.first.map { (0...100).contains($0.1.percent) } == true
        )
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

        try await settle { !spy.all.isEmpty }
        let saved = spy.all
        #expect(saved.count == 1)
        #expect(saved.first?.1.chapterKey == "ch2")
        #expect(saved.first?.1.epubCfi == "cfi-late")
    }

    @Test("relocated follows epub.js manifest-relative hrefs to spine chapters")
    func relocatedMatchesManifestRelativeHrefs() {
        let reader = ReaderModel()
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])

        // epub.js reports the section href manifest-relative; the core's
        // spine href is zip-root-relative. The suffix match must bridge.
        reader.relocated(page: 1, totalPages: 3, href: "sub/dir/two.xhtml", cfi: "cfi-2")
        #expect(reader.chapter?.key == "ch2")

        // An unknown href leaves the chapter alone.
        reader.relocated(page: 2, totalPages: 3, href: "elsewhere.xhtml", cfi: "cfi-3")
        #expect(reader.chapter?.key == "ch2")
    }

    @Test("chapter(forHref:) resolves exact, suffix, and basename matches")
    func chapterForHrefMatching() {
        let book = makeBook()
        #expect(ReaderModel.chapter(forHref: "one.xhtml", in: book)?.key == "ch1")
        #expect(ReaderModel.chapter(forHref: "OEBPS/two.xhtml", in: book)?.key == "ch2")
        #expect(ReaderModel.chapter(forHref: "deep/dir/two.xhtml", in: book)?.key == "ch2")
        #expect(ReaderModel.chapter(forHref: "missing.xhtml", in: book) == nil)
    }
}
