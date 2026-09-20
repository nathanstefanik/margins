import Foundation
@testable import MarginsCore
import Testing

/// Translated from the legacy core's notes test module, plus golden files
/// the legacy core wrote before the port. The theme running through the marks
/// tests is that a save must never rewrite a mark it was not asked to touch —
/// including through a file rename.
@Suite("Notes")
struct NotesTests {
    // MARK: Harness

    /// A book directory with `meta.json`, an empty notes index, and one
    /// chapter — the legacy suite's `seed_book`.
    private struct Book {
        let dir: String
        let chapter: ChapterMeta

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("margins-notes-\(UUID().uuidString)", isDirectory: true).path
            chapter = ChapterMeta(
                key: "001", index: 0, title: "Introduction", href: "OEBPS/chapter1.xhtml"
            )
            try Files.createDirectory(dir.appendingPathComponent("notes/chapters"))
            let meta = BookMeta(
                id: "abc123",
                title: "Sample Book",
                author: "Test Author",
                language: "en",
                addedAt: Date(),
                sourceFilename: "sample.epub",
                chapters: [chapter],
                chaptersVersion: 1
            )
            try Files.writeData(
                MarginsJSON.encode(meta), to: dir.appendingPathComponent("meta.json")
            )
            try Notes.writeEmptyIndex(bookDir: dir)
        }

        func frontmatter(epubCfi: String? = nil) -> NoteFrontmatter {
            NoteFrontmatter(
                bookId: "abc123",
                chapterKey: chapter.key,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                chapterHref: chapter.href,
                epubCfi: epubCfi,
                kind: "summary",
                wordCount: 0
            )
        }

        /// The marks region of a note file: sentinel line through end of
        /// file. The path comes from the index, which is the source of truth
        /// after a retitle rename.
        func marksRegion(_ chapterKey: String = "001") throws -> String {
            let index = try Notes.readIndex(bookDir: dir)
            let file = index.chapters.first { $0.chapterKey == chapterKey }?.file
                ?? "chapters/\(chapterKey)-\(Notes.slugify(chapter.title)).md"
            let raw = try Files.read(dir.appendingPathComponent("notes").appendingPathComponent(file))
            guard let start = raw.range(of: Marks.sentinel) else { return "" }
            return String(raw[start.lowerBound...])
        }

        /// Writes a note file with a hand-composed marks section, and an
        /// index entry pointing at it.
        func writeMarkedNote(body: String, marksRegion: String) throws {
            let file = "chapters/\(chapter.key)-\(Notes.slugify(chapter.title)).md"
            let content = """
            ---
            book_id: abc123
            chapter_key: '\(chapter.key)'
            chapter_index: \(chapter.index)
            chapter_title: \(chapter.title)
            chapter_href: \(chapter.href)
            kind: summary
            word_count: 3
            ---

            \(body)
            \(marksRegion)
            """
            try Files.write(
                content, to: dir.appendingPathComponent("notes").appendingPathComponent(file)
            )
            var index = try Notes.readIndex(bookDir: dir)
            index.chapters.append(
                NotesIndexEntry(
                    chapterKey: chapter.key, file: file, chapterIndex: chapter.index,
                    chapterTitle: chapter.title, wordCount: 3, markCount: 2, updatedAt: Date()
                )
            )
            try Files.writeData(
                MarginsJSON.encode(index),
                to: dir.appendingPathComponent("notes/_index.json")
            )
        }
    }

    private static let twoMarkSection = """
    \(Marks.sentinel)

    <!-- margins:mark id=baaaaaaaaaa cfi="epubcfi(/6/2!/4/2)" at=2026-09-05T10:00:00Z percent=12.5 -->
    > first quote

    first thought.

    <!-- margins:mark id=bbbbbbbbbbb cfi="epubcfi(/6/4!/4/6)" at=2026-09-05T11:00:00Z percent=48.0 -->
    > second quote

    second thought.

    """

    // MARK: Text helpers

    @Test("countWords skips markdown heading tokens")
    func countWordsSkipsHeadingTokens() {
        // "# Heading" tokenizes as "#" + "Heading"; only "#" is dropped.
        #expect(Notes.countWords("# Heading\none two") == 3)
        #expect(Notes.countWords("") == 0)
    }

    @Test("slugify makes file names from chapter titles")
    func slugifyChapterTitles() {
        #expect(Notes.slugify("The Market") == "the-market")
        #expect(Notes.slugify("  Hello!!! World  ") == "hello-world")
        // Truncation is by character, after trimming.
        #expect(Notes.slugify(String(repeating: "a", count: 60)).count == 48)
    }

    // MARK: Save and load

    @Test("save and load round-trip, updating the index")
    func saveAndLoadRoundTrip() throws {
        let book = try Book()
        let body = "This is a chapter summary with about twenty words so we can check "
            + "persistence of content and word count."

        let saved = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(epubCfi: "epubcfi(/6/2)"), body: body
        )
        #expect(Files.exists(saved.path))
        #expect(saved.frontmatter.wordCount == Notes.countWords(body))
        #expect(saved.frontmatter.createdAt != nil)
        #expect(try Notes.countNotes(bookDir: book.dir) == 1)

        let loaded = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001")
        #expect(loaded.body == body)
        #expect(loaded.frontmatter.kind == "summary")
        #expect(loaded.frontmatter.epubCfi == "epubcfi(/6/2)")

        let index = try Notes.readIndex(bookDir: book.dir)
        #expect(index.chapters.count == 1)
        #expect(index.chapters[0].file == "chapters/001-introduction.md")
    }

    @Test("a retitled chapter moves its note instead of orphaning it")
    func retitledChapterMovesItsNote() throws {
        let book = try Book()
        let first = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(), body: "first draft"
        )
        #expect(first.path.hasSuffix("001-introduction.md"))

        // The library scan re-derived the title from the book's TOC.
        var retitled = book.chapter
        retitled.title = "Opening Remarks"
        let second = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: retitled,
            frontmatter: book.frontmatter(), body: "second draft"
        )

        #expect(second.path.hasSuffix("001-opening-remarks.md"))
        #expect(first.frontmatter.createdAt == second.frontmatter.createdAt)
        #expect(!Files.exists(book.dir.appendingPathComponent("notes/chapters/001-introduction.md")))

        let index = try Notes.readIndex(bookDir: book.dir)
        #expect(index.chapters.count == 1)
        #expect(index.chapters[0].file == "chapters/001-opening-remarks.md")
        #expect(try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001").body == "second draft")
    }

    @Test("re-saving preserves createdAt and moves updatedAt")
    func resavePreservesCreatedAt() async throws {
        let book = try Book()
        let first = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(), body: "first draft"
        )
        try await Task.sleep(for: .milliseconds(5))
        let second = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(), body: "second draft with more words"
        )

        #expect(first.frontmatter.createdAt == second.frontmatter.createdAt)
        #expect(first.frontmatter.updatedAt != second.frontmatter.updatedAt)
        #expect(
            try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001").body
                == "second draft with more words"
        )
    }

    @Test("saving refuses to overwrite an evicted chapter note")
    func saveRefusesEvictedNote() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let book = try Book()
        let saved = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(), body: "original note"
        )
        let indexPath = book.dir.appendingPathComponent("notes/_index.json")
        let indexBefore = try Files.readData(indexPath)
        try Files.remove(saved.path)
        let fileName = (saved.path as NSString).lastPathComponent
        let placeholder = (saved.path as NSString).deletingLastPathComponent
            .appendingPathComponent(".\(fileName).icloud")
        try Files.write("placeholder", to: placeholder)

        FileStore.overrideContainerProvider { URL(fileURLWithPath: book.dir, isDirectory: true) }

        do {
            _ = try Notes.saveChapterNote(
                bookDir: book.dir, chapter: book.chapter,
                frontmatter: book.frontmatter(), body: "replacement note"
            )
            Issue.record("expected an evicted note to refuse the save")
        } catch let error as CoreError {
            #expect(error == .notDownloaded(saved.path))
        } catch {
            Issue.record("expected CoreError, got \(error)")
        }
        #expect(!Files.exists(saved.path))
        #expect(Files.exists(placeholder))
        #expect(try Files.readData(indexPath) == indexBefore)
    }

    @Test("retitling refuses to replace an evicted note at its old filename")
    func retitledSaveRefusesEvictedSourceNote() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let book = try Book()
        let saved = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(), body: "original note"
        )
        let indexPath = book.dir.appendingPathComponent("notes/_index.json")
        let indexBefore = try Files.readData(indexPath)
        try Files.remove(saved.path)
        let fileName = (saved.path as NSString).lastPathComponent
        let placeholder = (saved.path as NSString).deletingLastPathComponent
            .appendingPathComponent(".\(fileName).icloud")
        try Files.write("placeholder", to: placeholder)

        FileStore.overrideContainerProvider { URL(fileURLWithPath: book.dir, isDirectory: true) }
        var retitled = book.chapter
        retitled.title = "Opening Remarks"
        let destination = book.dir
            .appendingPathComponent("notes/chapters/001-opening-remarks.md")

        do {
            _ = try Notes.saveChapterNote(
                bookDir: book.dir, chapter: retitled,
                frontmatter: book.frontmatter(), body: "replacement note"
            )
            Issue.record("expected an evicted source note to refuse the retitled save")
        } catch let error as CoreError {
            #expect(error == .notDownloaded(saved.path))
        } catch {
            Issue.record("expected CoreError, got \(error)")
        }
        #expect(!Files.exists(saved.path))
        #expect(Files.exists(placeholder))
        #expect(!Files.exists(destination))
        #expect(try Files.readData(indexPath) == indexBefore)
    }

    @Test("loading a chapter with no note returns a blank one")
    func loadMissingNoteReturnsBlank() throws {
        let book = try Book()
        let note = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001")
        #expect(note.body.isEmpty)
        #expect(note.frontmatter.wordCount == 0)
        #expect(note.path.isEmpty)
    }

    @Test("clearing removes the files and resets the index")
    func clearRemovesFilesAndResetsIndex() throws {
        let book = try Book()
        try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: book.frontmatter(), body: "a note to lose"
        )
        #expect(try Notes.countNotes(bookDir: book.dir) == 1)

        #expect(try Notes.clearBookNotes(bookDir: book.dir) == 1)
        #expect(try Notes.countNotes(bookDir: book.dir) == 0)
        #expect(try Notes.readIndex(bookDir: book.dir).chapters.isEmpty)

        let note = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001")
        #expect(note.body.isEmpty)
        #expect(note.path.isEmpty)
    }

    @Test("clearing a book with no notes still writes an empty index")
    func clearWithoutNotesWritesEmptyIndex() throws {
        let book = try Book()
        #expect(try Notes.clearBookNotes(bookDir: book.dir) == 0)
        #expect(Files.exists(book.dir.appendingPathComponent("notes/_index.json")))
        #expect(try Notes.readIndex(bookDir: book.dir).chapters.isEmpty)
    }

    // MARK: Marks

    @Test("a marks-unaware save preserves marks byte-identically")
    func blobSavePreservesMarks() throws {
        let book = try Book()
        try book.writeMarkedNote(body: "Original prose.", marksRegion: Self.twoMarkSection)
        let before = try book.marksRegion()

        // A marks-unaware frontend edits the prose it loaded (long-form body
        // only) and saves through the ordinary path.
        var frontmatter = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001").frontmatter
        frontmatter.createdAt = nil
        frontmatter.updatedAt = nil
        let saved = try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter, frontmatter: frontmatter, body: "Edited prose."
        )

        #expect(saved.body == "Edited prose.")
        #expect(saved.marks.count == 2)
        #expect(try book.marksRegion() == before, "marks must be byte-identical")

        // Word count follows the long-form body only.
        #expect(saved.frontmatter.wordCount == Notes.countWords("Edited prose."))
        #expect(try Notes.readIndex(bookDir: book.dir).chapters[0].markCount == 2)
    }

    @Test("a save carrying marks in the body uses the body's version")
    func saveWithMarksInTheBodyWins() throws {
        let book = try Book()
        try book.writeMarkedNote(body: "Original prose.", marksRegion: Self.twoMarkSection)

        // A stale blob frontend saved back the whole body — with the user
        // hand-editing one mark's text in the textarea first.
        let edited = Self.twoMarkSection
            .replacingOccurrences(of: "second thought.", with: "hand-edited thought.")
        try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001").frontmatter,
            body: "Prose again.\n\n\(edited)"
        )

        let index = try Notes.readIndex(bookDir: book.dir)
        let raw = try Files.read(
            book.dir.appendingPathComponent("notes").appendingPathComponent(index.chapters[0].file)
        )
        #expect(raw.contains("hand-edited thought."))
        // The file's marks region equals the body's section, byte for byte.
        #expect(try book.marksRegion() == edited)
    }

    @Test("appending a mark creates the note file when the chapter has none")
    func appendMarkCreatesTheFile() throws {
        let book = try Book()
        let mark = try Notes.appendMark(
            bookDir: book.dir, chapter: book.chapter,
            cfi: "epubcfi(/6/2!/4/2)", percent: 33.0, quote: "a quote", body: "a thought"
        )
        #expect(mark.id.count == 10)
        #expect(mark.quote == "a quote")

        let loaded = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001")
        #expect(loaded.body.isEmpty)
        #expect(loaded.marks.count == 1)
        #expect(loaded.marks[0].id == mark.id)
        #expect(loaded.frontmatter.createdAt != nil)

        let index = try Notes.readIndex(bookDir: book.dir)
        #expect(index.chapters.count == 1)
        #expect(index.chapters[0].markCount == 1)
        #expect(index.chapters[0].wordCount == 0)
    }

    @Test("appending a mark keeps the body and the other marks' bytes")
    func appendMarkKeepsOtherBytes() throws {
        let book = try Book()
        try book.writeMarkedNote(body: "The long-form note.", marksRegion: Self.twoMarkSection)
        let before = try book.marksRegion()

        try Notes.appendMark(
            bookDir: book.dir, chapter: book.chapter,
            cfi: nil, percent: nil, quote: "", body: "a fresh thought"
        )

        let after = try book.marksRegion()
        // The original first block is a byte-identical run inside the new file.
        let firstBlock = try #require(before.range(of: "id=baaaaaaaaaa"))
        let secondBlock = try #require(before.range(of: "id=bbbbbbbbbbb"))
        let untouched = String(before[firstBlock.lowerBound..<secondBlock.lowerBound].trimmedEnd)
        #expect(after.contains(untouched))
        #expect(after.hasSuffix("a fresh thought\n"))

        let loaded = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001")
        #expect(loaded.body == "The long-form note.")
        #expect(loaded.marks.count == 3)

        let index = try Notes.readIndex(bookDir: book.dir)
        #expect(index.chapters[0].markCount == 3)
        #expect(index.chapters[0].wordCount == 3, "long-form word count unchanged")
    }

    @Test("update and delete touch only their own block")
    func updateAndDeleteTouchOneBlock() throws {
        let book = try Book()
        try book.writeMarkedNote(body: "Prose.", marksRegion: Self.twoMarkSection)
        let before = try book.marksRegion()
        let secondBlock = String(
            before[try #require(before.range(of: "id=bbbbbbbbbbb")).lowerBound...].trimmedEnd
        )

        // Update the first mark.
        let loaded = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001")
        var edited = loaded.marks[0]
        edited.body = "edited first thought"
        try Notes.updateMark(bookDir: book.dir, chapter: book.chapter, mark: edited)

        let afterUpdate = try book.marksRegion()
        #expect(afterUpdate.contains("edited first thought"))
        #expect(afterUpdate.contains(secondBlock), "untouched mark keeps its bytes")

        // Delete the first mark; the second is still untouched.
        try Notes.deleteMark(bookDir: book.dir, chapter: book.chapter, id: "baaaaaaaaaa")
        let afterDelete = try book.marksRegion()
        #expect(!afterDelete.contains("baaaaaaaaaa"))
        #expect(afterDelete.contains(secondBlock), "untouched mark keeps its bytes")
        #expect(afterDelete.contains("second thought."))
        #expect(try Notes.readIndex(bookDir: book.dir).chapters[0].markCount == 1)

        // Unknown ids are errors, not silent no-ops.
        #expect(throws: CoreError.self) {
            try Notes.updateMark(bookDir: book.dir, chapter: book.chapter, mark: loaded.marks[0])
        }
        #expect(throws: CoreError.self) {
            try Notes.deleteMark(bookDir: book.dir, chapter: book.chapter, id: "zzzzzzzzzzz")
        }
    }

    @Test("a retitling save keeps marks byte-identically through the rename")
    func retitledSaveKeepsMarks() throws {
        let book = try Book()
        // First save carries prose plus a marks section (body-authoritative).
        let markedBody = """
        Original prose.

        \(Marks.sentinel)

        <!-- margins:mark id=baaaaaaaaaa cfi="epubcfi(/6/2)" at=2026-09-05T10:00:00Z percent=12.5 -->
        > quote

        thought.

        """
        let frontmatter = try Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001").frontmatter
        try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter, frontmatter: frontmatter, body: markedBody
        )
        let before = try book.marksRegion()

        // The library scan re-derived the title; the next save renames the
        // file. Marks must survive the move byte-for-byte — the save reads
        // the file from its final path, not the pre-rename index entry.
        var retitled = book.chapter
        retitled.title = "Opening Remarks"
        try Notes.saveChapterNote(
            bookDir: book.dir, chapter: retitled, frontmatter: frontmatter, body: "Second draft."
        )

        #expect(Files.isFile(
            book.dir.appendingPathComponent("notes/chapters/001-opening-remarks.md")
        ))
        #expect(try book.marksRegion() == before)

        let index = try Notes.readIndex(bookDir: book.dir)
        #expect(index.chapters[0].file == "chapters/001-opening-remarks.md")
        #expect(index.chapters[0].markCount == 1)
    }

    @Test("unparsable content in the marks section survives saves")
    func unparsableContentSurvivesSaves() throws {
        let book = try Book()
        let blocks = String(
            Self.twoMarkSection[try #require(Self.twoMarkSection.range(of: "<!--")).lowerBound...]
        )
        try book.writeMarkedNote(
            body: "Prose.",
            marksRegion: """
            \(Marks.sentinel)

            stray line

            <!-- margins:mark id= oops -->
            > broken

            \(blocks)
            """
        )
        let before = try book.marksRegion()

        try Notes.saveChapterNote(
            bookDir: book.dir, chapter: book.chapter,
            frontmatter: Notes.loadChapterNote(bookDir: book.dir, chapterKey: "001").frontmatter,
            body: "New prose."
        )

        #expect(try book.marksRegion() == before)
    }

    // MARK: Golden files

    @Test("note files the legacy core wrote parse to the right values")
    func goldenNoteFilesParse() throws {
        let book = try Fixtures.copiedDirectory("notes/book").path

        let plain = try Notes.loadChapterNote(bookDir: book, chapterKey: "001")
        #expect(plain.frontmatter.chapterTitle == "Introduction")
        #expect(plain.frontmatter.wordCount == 11)
        #expect(plain.body == """
        # Introduction — Summary

        Your notes on this chapter.

        A second paragraph.
        """)
        #expect(plain.marks.isEmpty)

        let marked = try Notes.loadChapterNote(bookDir: book, chapterKey: "002")
        #expect(marked.body == "Long-form thoughts about the market.")
        #expect(marked.marks.count == 2)
        #expect(marked.marks[0].cfi == "epubcfi(/6/14!/4/2/10,/1:0,/1:42)")
        #expect(marked.marks[0].percent == 38.2)
        #expect(marked.marks[0].quote == "optional quoted selection from the book")
        #expect(marked.marks[0].body == "The quick thought.")
        // A page-anchored mark: empty cfi, no percent, no body.
        #expect(marked.marks[1].cfi == nil)
        #expect(marked.marks[1].percent == nil)
        #expect(marked.marks[1].quote == "a highlight with no note")
        #expect(marked.marks[1].body.isEmpty)

        let anchored = try Notes.loadChapterNote(bookDir: book, chapterKey: "003")
        #expect(anchored.frontmatter.epubCfi == "epubcfi(/6/6!/4/2/1:0)")
        #expect(anchored.frontmatter.chapterTitle == "A Title: With / Punctuation!")
    }

    @Test("re-saving a legacy-written note reproduces the file")
    func goldenNoteFilesReEmit() throws {
        let book = try Fixtures.copiedDirectory("notes/book").path
        let meta = try Notes.readMeta(bookDir: book)

        for chapter in meta.chapters {
            let file = book.appendingPathComponent("notes")
                .appendingPathComponent(
                    try #require(
                        Notes.readIndex(bookDir: book).chapters
                            .first { $0.chapterKey == chapter.key }?.file
                    )
                )
            let before = try Files.read(file)
            let loaded = try Notes.loadChapterNote(bookDir: book, chapterKey: chapter.key)

            try Notes.saveChapterNote(
                bookDir: book, chapter: chapter,
                frontmatter: loaded.frontmatter, body: loaded.body
            )

            // `updated_at` moves on every save and mark ids are generated, so
            // both are normalized exactly as the parity harness does.
            #expect(
                try Files.read(file).normalizingGeneratedValues
                    == before.normalizingGeneratedValues,
                "chapter \(chapter.key)"
            )
        }
    }
}
