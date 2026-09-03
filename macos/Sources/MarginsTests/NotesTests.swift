import Foundation
import Testing
import MarginsCore
import MarginsModel

@Suite("Notes")
struct NotesTests {
    @Test("save → reload round-trips through the markdown file")
    func saveAndReload() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixtures = try fixtureEpubs()
        let fixture = try #require(fixtures.first)
        let meta = try await store.importEpub(atPath: fixture)
        let chapter = try #require(meta.chapters.first)

        let body = "# Summary\n\nThe brothers argue about faith and doubt."
        let saved = try await store.saveChapterNote(
            bookId: meta.id,
            chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: body,
            kind: nil
        )
        #expect(!saved.path.isEmpty)
        #expect(saved.frontmatter.wordCount > 0)
        #expect(saved.frontmatter.createdAt != nil)
        #expect(saved.frontmatter.updatedAt != nil)

        // The on-disk file is markdown with YAML frontmatter — the exact
        // format the Tauri app writes (same core code path).
        let contents = try String(contentsOfFile: saved.path, encoding: .utf8)
        #expect(contents.hasPrefix("---\n"))
        #expect(contents.contains("book_id:"))
        #expect(contents.contains("chapter_key:"))
        #expect(contents.contains("word_count:"))
        #expect(contents.contains(body))

        let reloaded = try await store.getChapterNote(bookId: meta.id, chapterKey: chapter.key)
        #expect(reloaded.body == body)
        #expect(reloaded.frontmatter.wordCount == saved.frontmatter.wordCount)
    }

    @Test("updating a note preserves its creation time")
    func updatePreservesCreatedAt() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixtures = try fixtureEpubs()
        let fixture = try #require(fixtures.first)
        let meta = try await store.importEpub(atPath: fixture)
        let chapter = try #require(meta.chapters.first)
        let ref = ChapterRef(key: chapter.key, epubCfi: nil)

        let first = try await store.saveChapterNote(
            bookId: meta.id, chapter: ref, body: "first draft", kind: nil
        )
        let second = try await store.saveChapterNote(
            bookId: meta.id, chapter: ref, body: "second draft with more detail", kind: nil
        )
        #expect(second.frontmatter.createdAt == first.frontmatter.createdAt)
        #expect(second.path == first.path)

        let contents = try String(contentsOfFile: second.path, encoding: .utf8)
        #expect(contents.contains("second draft with more detail"))
        #expect(!contents.contains("first draft"))

        let reloaded = try await store.getChapterNote(bookId: meta.id, chapterKey: chapter.key)
        #expect(reloaded.body == "second draft with more detail")
    }

    @Test("search finds saved notes and reports their chapter")
    func searchFindsNotes() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixtures = try fixtureEpubs()
        let fixture = try #require(fixtures.first)
        let meta = try await store.importEpub(atPath: fixture)
        let chapter = try #require(meta.chapters.first)

        _ = try await store.saveChapterNote(
            bookId: meta.id,
            chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: "The xylophone-detective motif returns here.",
            kind: nil
        )

        let hits = try await store.searchNotes(query: "xylophone")
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.bookId == meta.id)
        #expect(hit.chapterKey == chapter.key)
        #expect(!hit.bookTitle.isEmpty)
        #expect(hit.snippet.contains("xylophone"))

        let misses = try await store.searchNotes(query: "qqqzzzunfindable")
        #expect(misses.isEmpty)
    }

    @Test("clearNotes deletes every note file and resets the index")
    func clearNotesRemovesAll() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let meta = try await store.importEpub(atPath: fixture)
        #expect(meta.chapters.count >= 2)

        _ = try await store.saveChapterNote(
            bookId: meta.id,
            chapter: ChapterRef(key: meta.chapters[0].key, epubCfi: nil),
            body: "first note",
            kind: nil
        )
        _ = try await store.saveChapterNote(
            bookId: meta.id,
            chapter: ChapterRef(key: meta.chapters[1].key, epubCfi: nil),
            body: "second note",
            kind: nil
        )

        let cleared = try await store.clearNotes(bookId: meta.id)
        #expect(cleared == 2)

        let index = try await store.notesIndex(bookId: meta.id)
        #expect(index.isEmpty)

        let reloaded = try await store.getChapterNote(bookId: meta.id, chapterKey: meta.chapters[0].key)
        #expect(reloaded.body.isEmpty)
        #expect(reloaded.path.isEmpty)

        // Clearing a book that already has no notes is a zero-count no-op.
        let again = try await store.clearNotes(bookId: meta.id)
        #expect(again == 0)
    }

    @Test("reader note state tracks dirty and saved baselines")
    @MainActor
    func readerNoteState() {
        let reader = ReaderModel()
        #expect(!reader.isNoteDirty)

        reader.noteLoaded(body: "loaded text", path: "/tmp/n.md", wordCount: 2, updatedAt: nil)
        #expect(!reader.isNoteDirty)
        #expect(reader.noteSaveStatus == .idle)

        reader.noteBody = "loaded text edited"
        #expect(reader.isNoteDirty)

        reader.noteSaved(
            path: "/tmp/n.md",
            wordCount: 3,
            updatedAt: "2026-09-02T00:00:00+00:00",
            savedBody: "loaded text edited"
        )
        #expect(!reader.isNoteDirty)
        #expect(reader.noteBody == "loaded text edited")
    }

    private final class SaveSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [(String, String, String)] = []

        func record(_ bookId: String, _ chapterKey: String, _ body: String) {
            lock.lock()
            saved.append((bookId, chapterKey, body))
            lock.unlock()
        }

        var all: [(String, String, String)] {
            lock.lock()
            defer { lock.unlock() }
            return saved
        }
    }

    @Test("notes autosave debounces typing bursts to one latest-wins save")
    @MainActor
    func autosaveDebounce() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        reader.noteSaveDebounce = 0.02
        reader.noteSaver = { bookId, chapterKey, body in
            spy.record(bookId, chapterKey, body)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteLoaded(body: "", path: nil, wordCount: 0, updatedAt: nil)

        reader.noteBody = "first burst"
        reader.noteEdited()
        reader.noteBody = "first burst plus more"
        reader.noteEdited()
        reader.noteBody = "final text after the burst"
        reader.noteEdited()

        try await Task.sleep(for: .milliseconds(250))
        let saved = spy.all
        #expect(saved.count == 1)
        #expect(saved.first?.1 == "ch1")
        #expect(saved.first?.2 == "final text after the burst")
        #expect(reader.noteSaveStatus == .saving || reader.noteSaveStatus == .edited)
    }

    @Test("switching chapters flushes the note for the old chapter")
    @MainActor
    func chapterChangeFlushesNote() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        reader.noteSaveDebounce = 10 // nothing debounced can fire in this test
        reader.noteSaver = { bookId, chapterKey, body in
            spy.record(bookId, chapterKey, body)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteLoaded(body: "", path: nil, wordCount: 0, updatedAt: nil)
        reader.noteBody = "chapter one summary in progress"
        reader.noteEdited()

        // n → next chapter: the pending edit flushes against chapter one.
        reader.nextChapter()
        try await Task.sleep(for: .milliseconds(100))

        let saved = spy.all
        #expect(saved.count == 1)
        #expect(saved.first?.1 == "ch1")
        #expect(saved.first?.2 == "chapter one summary in progress")
    }

    @Test("closing the reader flushes a pending note edit")
    @MainActor
    func closeFlushesNote() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        reader.noteSaveDebounce = 10
        reader.noteSaver = { bookId, chapterKey, body in
            spy.record(bookId, chapterKey, body)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteLoaded(body: "", path: nil, wordCount: 0, updatedAt: nil)
        reader.noteBody = "almost done typing"
        reader.noteEdited()
        reader.close()

        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.all.count == 1)
    }

    @Test("typing during a save keeps the editor marked edited")
    @MainActor
    func typingDuringSaveStaysEdited() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        reader.noteSaver = { bookId, chapterKey, body in
            spy.record(bookId, chapterKey, body)
        }
        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteLoaded(body: "", path: nil, wordCount: 0, updatedAt: nil)

        reader.noteBody = "saved snapshot"
        reader.flushNoteSave()
        #expect(reader.noteSaveStatus == .saving)

        // The user keeps typing while the save is in flight.
        reader.noteBody = "saved snapshot and more"
        reader.noteSaved(
            path: "/tmp/n.md", wordCount: 4, updatedAt: nil, savedBody: "saved snapshot"
        )
        #expect(reader.isNoteDirty, "newer edits must not be swallowed as saved")
        #expect(reader.noteSaveStatus == .edited)

        // Completing a save that matches the current body marks it saved.
        reader.noteSaved(
            path: "/tmp/n.md", wordCount: 4, updatedAt: nil,
            savedBody: "saved snapshot and more"
        )
        #expect(!reader.isNoteDirty)
        #expect(reader.noteSaveStatus == .saved)
        try await Task.sleep(for: .milliseconds(50)) // let the detached save land
    }

    @Test("closeNotes flushes pending edits and hides the pane")
    @MainActor
    func closeNotesFlushesAndHides() async throws {
        let spy = SaveSpy()
        let reader = ReaderModel()
        reader.noteSaveDebounce = 10
        reader.noteSaver = { bookId, chapterKey, body in
            spy.record(bookId, chapterKey, body)
        }

        let book = makeBook()
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteLoaded(body: "", path: nil, wordCount: 0, updatedAt: nil)
        reader.openNotes()
        #expect(reader.notesVisible)

        reader.noteBody = "esc cascade draft"
        reader.noteEdited()
        reader.closeNotes()

        #expect(!reader.notesVisible)
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.all.count == 1)
        #expect(spy.all.first?.2 == "esc cascade draft")

        // Esc on an already-closed pane is a no-op.
        reader.closeNotes()
        #expect(spy.all.count == 1)
    }

    @Test("notes header formats chapter number and title")
    func notesHeaderFormatting() {
        #expect(
            ReaderModel.noteHeaderText(chapterIndex: 2, chapterTitle: "The Market")
                == "Ch. 3 · The Market"
        )
        #expect(ReaderModel.noteHeaderText(chapterIndex: 0, chapterTitle: "One") == "Ch. 1 · One")

        // Missing, empty, or whitespace-only titles fall back to the number.
        #expect(ReaderModel.noteHeaderText(chapterIndex: 4, chapterTitle: nil) == "Ch. 5")
        #expect(ReaderModel.noteHeaderText(chapterIndex: 4, chapterTitle: "") == "Ch. 5")
        #expect(ReaderModel.noteHeaderText(chapterIndex: 4, chapterTitle: "   ") == "Ch. 5")

        // Long titles are returned whole; the view truncates them.
        let long = String(repeating: "A very long chapter title,", count: 10)
        #expect(
            ReaderModel.noteHeaderText(chapterIndex: 0, chapterTitle: long)
                == "Ch. 1 · \(long)"
        )
    }

    private func makeBook() -> BookMeta {
        BookMeta(
            id: "book-1",
            title: "Test Book",
            author: "Author",
            language: "en",
            addedAt: "2026-01-01",
            sourceFilename: "test.epub",
            chapters: [
                ChapterMeta(key: "ch1", index: 0, title: "One", href: "one.xhtml", fragment: nil),
                ChapterMeta(key: "ch2", index: 1, title: "Two", href: "two.xhtml", fragment: nil),
            ],
            coverPath: nil,
            progressPercent: nil
        )
    }
}
