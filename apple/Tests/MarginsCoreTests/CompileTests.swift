import Foundation
@testable import MarginsKernel
import Testing

/// Translated from `crates/margins-core/src/compile.rs`'s test module. The
/// snapshot test is the load-bearing one: markdown output must stay
/// byte-identical to what the Rust core rendered.
@Suite("Compile")
struct CompileTests {
    // MARK: Harness

    private enum TestError: Error {
        case missingEntry(String)
    }

    /// A book directory with `meta.json`, an empty notes index, and the
    /// given spine — the Rust suite's `TestBook`.
    private struct TestBook {
        let dir: String

        init(_ chapters: [(key: String, title: String)]) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("margins-compile-\(UUID().uuidString)", isDirectory: true)
                .path
            let spine = chapters.enumerated().map { index, chapter in
                ChapterMeta(
                    key: chapter.key, index: index, title: chapter.title,
                    href: "OEBPS/ch\(index).xhtml"
                )
            }
            let meta = BookMeta(
                id: "abc123",
                title: "Sample Book",
                author: "Test Author",
                language: "en",
                addedAt: Date(),
                sourceFilename: "sample.epub",
                chapters: spine,
                chaptersVersion: Library.chaptersVersion
            )
            try Files.createDirectory(dir.appendingPathComponent("notes/chapters"))
            try Files.writeData(
                MarginsJSON.encode(meta), to: dir.appendingPathComponent("meta.json")
            )
            try Notes.writeEmptyIndex(bookDir: dir)
        }

        /// Writes a note file with fixed frontmatter dates plus its index
        /// entry — bypassing `saveChapterNote` so timestamps are
        /// deterministic for the snapshot test.
        func writeNote(key: String, index: Int, title: String, body: String) throws {
            let updated = fixedDate(1_700_000_000 + Double(index) * 86_400)
            let created = fixedDate(1_699_000_000 + Double(index) * 86_400)
            let frontmatter = """
            ---
            book_id: abc123
            chapter_key: '\(key)'
            chapter_index: \(index)
            chapter_title: '\(title)'
            chapter_href: OEBPS/ch\(index).xhtml
            epub_cfi: null
            kind: summary
            word_count: 0
            created_at: \(RFC3339.string(from: created))
            updated_at: \(RFC3339.string(from: updated))
            ---

            """
            let file = "chapters/\(key)-note.md"
            try Files.write(
                frontmatter + body,
                to: dir.appendingPathComponent("notes").appendingPathComponent(file)
            )

            var doc = try Notes.readIndex(bookDir: dir)
            doc.chapters.append(
                NotesIndexEntry(
                    chapterKey: key, file: file, chapterIndex: index, chapterTitle: title,
                    wordCount: Notes.countWords(body), updatedAt: updated
                )
            )
            try Files.writeData(
                MarginsJSON.encode(doc), to: dir.appendingPathComponent("notes/_index.json")
            )
        }

        /// Rewrites `_index.json` with the listed keys in the given order, to
        /// prove compilation does not trust index ordering.
        func shuffleIndex(_ order: [String]) throws {
            var doc = try Notes.readIndex(bookDir: dir)
            let chapters = doc.chapters
            doc.chapters = try order.map { key in
                guard let entry = chapters.first(where: { $0.chapterKey == key }) else {
                    throw TestError.missingEntry(key)
                }
                return entry
            }
            try Files.writeData(
                MarginsJSON.encode(doc), to: dir.appendingPathComponent("notes/_index.json")
            )
        }
    }

    private static func fixedDate(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: Compiling

    @Test("compile prefers the spine title over stale frontmatter")
    func compilePrefersSpineTitle() throws {
        let book = try TestBook([("001", "Chapter II. The Real Name")])
        // Written before the chapter titles were re-derived, so the note
        // still carries the old name.
        try book.writeNote(key: "001", index: 0, title: "Chapter 1", body: "Body.")

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let chapter = try #require(compiled.chapters.first)
        #expect(chapter.chapterTitle == "Chapter II. The Real Name")
    }

    @Test("compile falls back to frontmatter for keys off the spine")
    func compileFallsBackToFrontmatter() throws {
        let book = try TestBook([("001", "Opening")])
        try book.writeNote(key: "009", index: 8, title: "An Orphaned Note", body: "Body.")

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let chapter = try #require(compiled.chapters.first)
        #expect(chapter.chapterTitle == "An Orphaned Note")
    }

    @Test("compile orders by chapter index even when the index is shuffled")
    func compileOrdersByChapterIndex() throws {
        let book = try TestBook([
            ("001", "Introduction"), ("002", "Middle"), ("003", "End"),
        ])
        try book.writeNote(key: "001", index: 0, title: "Introduction", body: "first note body")
        try book.writeNote(key: "003", index: 2, title: "End", body: "last note body")
        try book.shuffleIndex(["003", "001"])

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        #expect(compiled.chapters.map(\.chapterKey) == ["001", "003"])
        #expect(compiled.chaptersWithNotes == 2)
        #expect(compiled.chapterCount == 3)
    }

    @Test("compile omits noteless chapters but counts them")
    func compileOmitsNotelessChapters() throws {
        let book = try TestBook([
            ("001", "Introduction"), ("002", "Middle"), ("003", "End"),
        ])
        try book.writeNote(key: "001", index: 0, title: "Introduction", body: "first note body")
        try book.writeNote(key: "003", index: 2, title: "End", body: "last note body")

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        #expect(compiled.chapters.count == 2)
        #expect(compiled.chaptersWithNotes == 2)
        #expect(compiled.chapterCount == 3)
        #expect(compiled.emptyChapters.map(\.chapterKey) == ["002"])
        #expect(compiled.totalWords == compiled.chapters.map(\.wordCount).reduce(0, +))
        #expect(compiled.firstCreatedAt != nil)
        #expect(compiled.lastUpdatedAt != nil)
        #expect(!compiled.suggestedFilename.isEmpty)
    }

    @Test("compile includes marks in reading order and the export")
    func compileIncludesMarksInReadingOrder() throws {
        let book = try TestBook([("001", "Introduction")])
        // Marks written out of reading order on disk; the last one is
        // page-anchored (no CFI, no percent).
        let marksSection = """
        \(Marks.sentinel)

        <!-- margins:mark id=bbbbbbbbbbb cfi="epubcfi(/6/4!/4/6)" at=2026-09-05T11:00:00Z percent=51.0 -->
        > later quote

        later thought.

        <!-- margins:mark id=ccccccccccc cfi="" at=2026-09-05T12:00:00Z -->

        page-anchored thought.

        <!-- margins:mark id=aaaaaaaaaaa cfi="epubcfi(/6/2!/4/2)" at=2026-09-05T10:00:00Z percent=38.2 -->
        > a quote

        a thought.
        """
        let content = """
        ---
        book_id: abc123
        chapter_key: '001'
        chapter_index: 0
        chapter_title: 'Introduction'
        chapter_href: OEBPS/ch0.xhtml
        epub_cfi: null
        kind: summary
        word_count: 2
        created_at: 2026-09-05T09:00:00Z
        updated_at: 2026-09-05T09:30:00Z
        ---

        Prose body.

        \(marksSection)
        """
        try Files.write(
            content, to: book.dir.appendingPathComponent("notes/chapters/001-introduction.md")
        )
        var doc = try Notes.readIndex(bookDir: book.dir)
        doc.chapters.append(
            NotesIndexEntry(
                chapterKey: "001", file: "chapters/001-introduction.md", chapterIndex: 0,
                chapterTitle: "Introduction", wordCount: 2, markCount: 3,
                updatedAt: RFC3339.date(from: "2026-09-05T09:30:00+00:00")
            )
        )
        try Files.writeData(
            MarginsJSON.encode(doc), to: book.dir.appendingPathComponent("notes/_index.json")
        )

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let chapter = try #require(compiled.chapters.first)
        #expect(chapter.body == "Prose body.")
        #expect(
            chapter.marks.map(\.percent) == [38.2, 51.0, nil],
            "reading order: percent ascending, page-anchored last"
        )

        let export = Compile.renderMarkdown(compiled)
        #expect(export.contains("### Marks"))
        #expect(export.contains("> a quote"))
        #expect(export.contains("page-anchored thought."))
        #expect(export.contains("*— 38.2% · "))
        #expect(
            export.contains("*— Sep 5, 2026*"),
            "percent-less mark gets a date-only attribution"
        )
        #expect(
            !export.contains("margins:mark"),
            "no HTML comments ever reach the export"
        )
    }

    @Test("compile skips a corrupt note and still succeeds")
    func compileSkipsCorruptNote() throws {
        let book = try TestBook([("001", "Introduction"), ("002", "Middle")])
        try book.writeNote(key: "001", index: 0, title: "Introduction", body: "first note body")
        try book.writeNote(key: "002", index: 1, title: "Middle", body: "second note body")
        // Corrupt one file: no frontmatter, unparsable.
        try Files.write(
            "garbage without frontmatter",
            to: book.dir.appendingPathComponent("notes/chapters/002-note.md")
        )

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        #expect(compiled.chapters.map(\.chapterKey) == ["001"])
        // The corrupt chapter counts as note-less, not as an error.
        #expect(compiled.chaptersWithNotes == 1)
        #expect(compiled.emptyChapters.count == 1)
    }

    // MARK: Rendering

    @Test("render markdown snapshot")
    func renderMarkdownSnapshot() throws {
        let book = try TestBook([
            ("001", "Introduction"), ("002", "Skipped"), ("003", "The Market"),
        ])
        try book.writeNote(
            key: "001", index: 0, title: "Introduction",
            body: "Plain start.\n\n# My Heading\n## Sub heading"
        )
        try book.writeNote(
            key: "003", index: 2, title: "The Market", body: "Market notes with *emphasis*."
        )

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let out = Compile.renderMarkdown(compiled)
        let expected = """
        # Notes — Sample Book

        *Test Author* · 2/3 chapters annotated · 10 words · last updated Nov 16, 2023

        ## Contents

        - [1. Introduction](#1-introduction)
        - [3. The Market](#3-the-market)

        ---

        ## 1. Introduction

        *6 words · updated Nov 14, 2023*

        Plain start.

        ### My Heading
        #### Sub heading

        ---

        ## 3. The Market

        *4 words · updated Nov 16, 2023*

        Market notes with *emphasis*.


        """
        #expect(out == expected)
    }

    @Test("render includes empty chapter stubs when asked")
    func renderIncludesEmptyChapterStubs() throws {
        let book = try TestBook([("001", "Introduction"), ("002", "Middle")])
        try book.writeNote(key: "001", index: 0, title: "Introduction", body: "first note body")

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let options = ExportOptions(includeEmptyChapters: true)
        let out = Compile.renderMarkdown(compiled, options: options)
        #expect(out.contains("- [2. Middle](#2-middle)"))
        #expect(out.contains("## 2. Middle\n\n_No note._"))

        // Default export keeps the gaps invisible.
        let defaultOut = Compile.renderMarkdown(compiled)
        #expect(!defaultOut.contains("Middle"))
    }

    @Test("render empty book produces a no-notes document")
    func renderEmptyBook() throws {
        let book = try TestBook([("001", "Introduction"), ("002", "Middle")])

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let out = Compile.renderMarkdown(compiled)
        #expect(
            out
                == "# Notes — Sample Book\n\n*Test Author* · 0/2 chapters annotated · 0 words\n\n_No notes yet._\n"
        )
    }

    @Test("toc anchor collisions get numeric suffixes")
    func tocAnchorCollisions() {
        // Distinct chapter numbers make base slugs distinct; collisions
        // only arise from identical inputs (or future slug changes), so
        // the dedupe is exercised on the helper directly.
        var seen: [String: Int] = [:]
        #expect(Compile.tocAnchor(0, "Same Title", seen: &seen) == "1-same-title")
        #expect(Compile.tocAnchor(0, "Same Title", seen: &seen) == "1-same-title-2")
        #expect(Compile.tocAnchor(0, "Same Title", seen: &seen) == "1-same-title-3")
    }

    // MARK: Filenames

    @Test("filename helper strips path-hostile characters")
    func filenameHelperStripsHostileCharacters() throws {
        let book = try TestBook([("001", "Introduction")])
        let data = try Files.readData(book.dir.appendingPathComponent("meta.json"))
        var meta = try MarginsJSON.decode(BookMeta.self, from: data)
        meta.title = "Weird: Title/With?Slashes*"
        meta.author = "Anne/Sophie: Author"
        try Files.writeData(
            MarginsJSON.encode(meta), to: book.dir.appendingPathComponent("meta.json")
        )

        let compiled = try Compile.bookNotes(bookDir: book.dir)
        let filename = Compile.suggestedExportFilename(compiled)
        #expect(filename == "Anne Sophie Author — Weird Title With Slashes — notes.md")
        #expect(!filename.contains("/") && !filename.contains(":"))
    }

    @Test("suggested filename survives empty strings")
    func suggestedFilenameSurvivesEmptyStrings() {
        let notes = CompiledNotes(
            bookId: "x",
            bookTitle: "",
            bookAuthor: "",
            chapters: [],
            emptyChapters: [],
            chaptersWithNotes: 0,
            chapterCount: 0,
            totalWords: 0,
            firstCreatedAt: nil,
            lastUpdatedAt: nil,
            suggestedFilename: ""
        )
        #expect(Compile.suggestedExportFilename(notes) == " —  — notes.md")
    }
}
