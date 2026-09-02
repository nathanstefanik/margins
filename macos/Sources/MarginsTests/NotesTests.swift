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

    @Test("reader note state tracks dirty and saved baselines")
    @MainActor
    func readerNoteState() {
        let reader = ReaderModel()
        #expect(!reader.isNoteDirty)

        reader.noteLoaded(body: "loaded text", path: "/tmp/n.md", wordCount: 2, updatedAt: nil)
        #expect(!reader.isNoteDirty)

        reader.noteBody = "loaded text edited"
        #expect(reader.isNoteDirty)

        reader.noteSaved(path: "/tmp/n.md", wordCount: 3, updatedAt: "2026-09-02T00:00:00+00:00")
        #expect(!reader.isNoteDirty)
        #expect(reader.noteBody == "loaded text edited")
    }
}
