import Foundation
@testable import MarginsCore
import Testing

/// Read-compatibility with files the Rust core wrote before it was deleted
/// (docs/apple-only-plan.md Phase 2 step 7 kept `Fixtures/legacy-library/`
/// for exactly this): a library seeded by `margins-core` with the Karamazov
/// fixture, two notes with marks, and a saved position. The Swift core must
/// open it as-is — same ids, titles, notes, marks, positions, search
/// results — because users' existing libraries were written by Rust.
@Suite("Legacy library")
struct LegacyLibraryTests {
    private static func openLegacyLibrary() throws -> (Library, String) {
        let root = try Fixtures.copiedDirectory("legacy-library")
        let library = try Library(root: root.path)
        let summaries = try library.listBooks()
        guard summaries.count == 1 else {
            throw Fixtures.FixtureError.missing("legacy-library must contain exactly one book")
        }
        return (library, summaries[0].id)
    }

    @Test("the catalog lists the Rust-imported book with its id and metadata")
    func catalog() throws {
        let (library, id) = try Self.openLegacyLibrary()
        #expect(id == "c75274830529adb9b7f4a1e3", "the id is the content hash the Rust core computed")

        let meta = try library.getBook(id: id)
        #expect(meta.title == "The Brothers Karamazov")
        #expect(meta.author == "Fyodor Dostoyevsky")
        #expect(meta.chapters.count > 3)
        #expect(meta.chapters[0].key == "001")
        #expect(meta.progressPercent == 25.0, "the seeded position feeds the catalog")
    }

    @Test("notes written by the Rust core load with their marks")
    func notes() throws {
        let (library, id) = try Self.openLegacyLibrary()
        let index = try Notes.readIndex(bookDir: library.bookDir(id))
        #expect(index.chapters.map(\.chapterKey) == ["001", "003"])
        #expect(index.chapters.map(\.wordCount) == [16, 9])
        #expect(index.chapters.map(\.markCount) == [1, 1])

        let note = try Notes.loadChapterNote(bookDir: library.bookDir(id), chapterKey: "001")
        #expect(note.body.contains("xylophone motif begins here"))
        #expect(note.marks.count == 1)
        #expect(note.marks[0].percent == 12.5)
        #expect(note.marks[0].quote == "opening line")
    }

    @Test("the reading position round-trips")
    func position() throws {
        let (library, id) = try Self.openLegacyLibrary()
        let position = try #require(library.readPosition(bookID: id))
        #expect(position.chapterKey == "002")
        #expect(position.epubCfi == nil)
        #expect(position.percent == 25.0)
    }

    @Test("compiling and rendering agree with what the Rust core stored")
    func compileAndRender() throws {
        let (library, id) = try Self.openLegacyLibrary()
        let compiled = try Compile.bookNotes(bookDir: library.bookDir(id))
        #expect(compiled.chaptersWithNotes == 2)
        #expect(compiled.chapterCount == compiled.chaptersWithNotes + compiled.emptyChapters.count)
        #expect(compiled.totalWords == 25)
        #expect(compiled.chapters.map(\.chapterKey) == ["001", "003"])

        // Reading order: the seeded marks are one percent-anchored (12.5%)
        // and one page-anchored, which sorts last.
        #expect(compiled.chapters[0].marks.map(\.percent) == [12.5])
        #expect(compiled.chapters[1].marks.map(\.percent) == [nil])

        let render = Compile.renderMarkdown(compiled)
        #expect(render.contains("# Notes — The Brothers Karamazov"))
        #expect(render.contains("### Marks"))
        #expect(render.contains("*— 12.5% · "))
        #expect(render.contains("*— Sep 10, 2026*"))
    }

    @Test("search over the Rust-written notes")
    func search() throws {
        let (library, id) = try Self.openLegacyLibrary()
        let hits = library.searchNotes(query: "xylophone")
        #expect(hits.count == 1)
        #expect(hits.first?.chapterKey == "001")
        #expect(hits.first?.kind == .noteContent)
        #expect(hits.first?.snippet.contains("xylophone") == true)
    }

    @Test("a save through the Swift core stays in the storage format")
    func saveKeepsFormat() throws {
        let (library, id) = try Self.openLegacyLibrary()
        let meta = try library.getBook(id: id)
        let chapter = meta.chapters[2]
        let saved = try Notes.saveChapterNote(
            bookDir: library.bookDir(id), chapter: chapter,
            frontmatter: NoteFrontmatter(
                bookId: id, chapterKey: chapter.key, chapterIndex: chapter.index,
                chapterTitle: chapter.title, chapterHref: chapter.href,
                epubCfi: nil, kind: "summary", wordCount: 0
            ),
            body: "A fresh note from the Swift core."
        )
        #expect(saved.path.hasSuffix("chapters/003-part-i.md"))

        // The re-emitted file still parses, and the index keeps its
        // chapter-index ordering.
        let reread = try Notes.loadChapterNote(bookDir: library.bookDir(id), chapterKey: chapter.key)
        #expect(reread.body == "A fresh note from the Swift core.")
        let index = try Notes.readIndex(bookDir: library.bookDir(id))
        #expect(index.chapters.map(\.chapterIndex) == [0, 2])
    }
}
