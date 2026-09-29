import Foundation
import Testing

@testable import MarginsCore

/// Notebooks (docs/commonplace.md "Notebook storage"): one markdown file
/// per notebook under `{root}/notebooks/`, a derived `_index.json`, and a
/// lossless round-trip contract — a save rewrites only the passage blocks
/// whose live resolution actually changed.
@Suite("Notebooks")
struct NotebooksTests {
    /// A temp library root with the two-chapter sample EPUB imported.
    private struct Harness {
        let root: URL
        let library: Library
        let bookID: String
        let chapters: [ChapterMeta]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("margins-notebooks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try Library(root: root.appendingPathComponent("library").path)
            let epub = try EpubFixtureBuilder.sampleEpub(in: root)
            let meta = try library.importEpub(atPath: epub)
            bookID = meta.id
            chapters = meta.chapters
        }

        var notebooksDir: String {
            library.root.appendingPathComponent("notebooks")
        }

        /// The post-frontmatter bytes of a notebook file — the body the
        /// round-trip tests compare byte for byte.
        func body(ofFile file: String) throws -> String {
            let raw = try Files.read(notebooksDir.appendingPathComponent(file))
            guard let close = raw.range(of: "\n---\n") else {
                throw Fixtures.FixtureError.missing("frontmatter fence in \(file)")
            }
            return String(raw[close.upperBound...])
        }

        /// Writes a notebook file by hand (id/title/dates fixed), for tests
        /// that need exact body bytes on disk.
        @discardableResult
        func writeNotebook(id: String, title: String, body: String) throws -> String {
            try Files.createDirectory(notebooksDir)
            let file = "hand-\(id).md"
            let content =
                "---\nid: \(id)\ntitle: '\(title)'\n"
                + "created_at: 2026-09-29T10:00:00Z\nupdated_at: 2026-09-29T10:00:00Z\n---\n"
                + body
            try Files.write(content, to: notebooksDir.appendingPathComponent(file))
            return file
        }

    }

    // MARK: Create / list

    @Test("create writes the file, the index entry, and the listing")
    func create() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "Self-deception")

        #expect(summary.id.count == 10)
        #expect(summary.file == "self-deception.md")
        #expect(summary.title == "Self-deception")

        let path = harness.notebooksDir.appendingPathComponent("self-deception.md")
        let raw = try Files.read(path)
        #expect(raw.contains("id: \(summary.id)"))
        #expect(raw.contains("title: 'Self-deception'"))
        #expect(raw.contains("created_at:"))
        #expect(raw.contains("updated_at:"))

        // The index carries the derived catalog entry.
        let index = try MarginsJSON.decode(
            NotebooksIndex.self,
            from: Files.readData(harness.notebooksDir.appendingPathComponent("_index.json"))
        )
        #expect(index.notebooks.map(\.id) == [summary.id])

        #expect(try harness.library.listNotebooks().map(\.id) == [summary.id])
    }

    @Test("colliding titles suffix the file name")
    func slugCollision() throws {
        let harness = try Harness()
        let first = try harness.library.createNotebook(title: "Same Title")
        let second = try harness.library.createNotebook(title: "Same Title")
        let third = try harness.library.createNotebook(title: "Same Title")
        #expect(first.file == "same-title.md")
        #expect(second.file == "same-title-2.md")
        #expect(third.file == "same-title-3.md")
        #expect(first.id != second.id)
    }

    @Test("a title with no slug characters becomes notebook.md")
    func unspluggableTitle() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "???")
        #expect(summary.file == "notebook.md")
        #expect(summary.title == "???")
    }

    @Test("an empty title is an error, not a file")
    func emptyTitleFails() throws {
        let harness = try Harness()
        #expect(throws: CoreError.self) {
            try harness.library.createNotebook(title: "   ")
        }
        #expect(try harness.library.listNotebooks().isEmpty)
    }

    // MARK: Rename / delete

    @Test("rename moves the file and keeps the id")
    func rename() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "Before")

        let renamed = try harness.library.renameNotebook(id: summary.id, title: "After All")
        #expect(renamed.id == summary.id)
        #expect(renamed.title == "After All")
        #expect(renamed.file == "after-all.md")
        #expect(!Files.exists(harness.notebooksDir.appendingPathComponent("before.md")))
        #expect(Files.exists(harness.notebooksDir.appendingPathComponent("after-all.md")))

        let index = try MarginsJSON.decode(
            NotebooksIndex.self,
            from: Files.readData(harness.notebooksDir.appendingPathComponent("_index.json"))
        )
        #expect(index.notebooks.map(\.file) == ["after-all.md"])

        // Colliding with another notebook's file still disambiguates.
        let other = try harness.library.createNotebook(title: "After All")
        #expect(other.file == "after-all-2.md")
    }

    @Test("delete removes the file and the index entry")
    func delete() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "Doomed")
        try harness.library.deleteNotebook(id: summary.id)
        #expect(try harness.library.listNotebooks().isEmpty)
        #expect(!Files.exists(harness.notebooksDir.appendingPathComponent(summary.file)))
        #expect(throws: CoreError.self) {
            try harness.library.notebook(id: summary.id)
        }
    }

    @Test("an unknown id is an error, not a silent no-op")
    func unknownID() throws {
        let harness = try Harness()
        #expect(throws: CoreError.self) {
            try harness.library.renameNotebook(id: "zzzzzzzzzz", title: "x")
        }
        #expect(throws: CoreError.self) {
            try harness.library.deleteNotebook(id: "zzzzzzzzzz")
        }
    }

    @Test("a title with quotes and unicode round-trips through frontmatter")
    func titleRoundTrip() throws {
        let harness = try Harness()
        let title = #"It's: a "test" — ünïcode"#
        let summary = try harness.library.createNotebook(title: title)
        let raw = try Files.read(harness.notebooksDir.appendingPathComponent(summary.file))
        // Always single-quoted; an internal quote doubles.
        #expect(raw.contains("title: 'It''s: a \"test\" — ünïcode'"))
        #expect(try harness.library.listNotebooks().first?.title == title)
        #expect(try harness.library.notebook(id: summary.id).summary.title == title)
    }

    // MARK: Lossless round-trips

    /// Writes a notebook file with `body`, saves the loaded segments back
    /// unchanged, and asserts the body bytes are identical.
    private func assertLossless(
        _ body: String, harness: Harness, id: String = "baaaaaaaaa"
    ) throws {
        let fileName = try harness.writeNotebook(id: id, title: "Lossless", body: body)
        let before = try harness.body(ofFile: fileName)
        let loaded = try harness.library.notebook(id: id)
        _ = try harness.library.saveNotebook(id: id, segments: loaded.segments)
        let after = try harness.body(ofFile: fileName)
        #expect(after == before)
    }

    @Test("prose-only bodies round-trip byte for byte")
    func losslessProse() throws {
        let harness = try Harness()
        try assertLossless("\nJust prose.\n\nTwo paragraphs.\n", harness: harness)
        try assertLossless("", harness: harness)
        try assertLossless("no leading or trailing newline", harness: harness)
    }

    @Test("a passage-first body round-trips byte for byte")
    func losslessPassageFirst() throws {
        let harness = try Harness()
        let body = """
            <!-- margins:passage book=abc123 chapter=001 mark=baaaaaaaaa -->
            > Above all, don't lie to yourself.
            > — Fyodor Dostoyevsky, *The Brothers Karamazov*, Book II

            Trailing prose.
            """
        // The mark doesn't exist in the fixture book → unresolved → the
        // block is emitted verbatim.
        try assertLossless(body, harness: harness)
    }

    @Test("a passage at the end without a trailing newline round-trips")
    func losslessPassageLastNoNewline() throws {
        let harness = try Harness()
        // No trailing newline after the citation line — the file just ends.
        let body = """
            Intro prose.

            <!-- margins:passage book=abc123 chapter=001 mark=baaaaaaaaa -->
            > a quote
            """ + "> — Test Author, *Sample Book*, Introduction"
        try assertLossless(body, harness: harness)
    }

    @Test("two adjacent passages stay adjacent")
    func losslessAdjacentPassages() throws {
        let harness = try Harness()
        let body = """
            <!-- margins:passage book=abc123 chapter=001 mark=baaaaaaaaa -->
            > first
            > — A, *B*, C
            <!-- margins:passage book=abc123 chapter=002 mark=bbbbbbbbbb -->
            > second
            > — A, *B*, C
            """
        try assertLossless(body, harness: harness)
    }

    @Test("a mangled passage comment stays prose")
    func mangledCommentIsProse() throws {
        let harness = try Harness()
        // No mark= attribute → not a passage: prose, kept verbatim.
        let body = """
            <!-- margins:passage book=abc123 chapter=001 -->
            > looks like a quote
            > — Test Author, *Sample Book*, Introduction
            """
        try assertLossless(body, harness: harness)

        let loaded = try harness.library.notebook(id: "baaaaaaaaa")
        #expect(loaded.segments.count == 1)
        guard case .prose = loaded.segments[0].content else {
            Issue.record("mangled passage comment should parse as prose")
            return
        }
        #expect(loaded.summary.passageCount == 0)
    }

    @Test("editing one prose segment leaves every other byte alone")
    func editOneProseSegment() throws {
        let harness = try Harness()
        let body = """
            first paragraph

            <!-- margins:passage book=abc123 chapter=001 mark=baaaaaaaaa -->
            > a quote
            > — Test Author, *Sample Book*, Introduction

            second paragraph
            """
        let fileName = try harness.writeNotebook(id: "baaaaaaaaa", title: "Edit", body: body)
        let loaded = try harness.library.notebook(id: "baaaaaaaaa")
        #expect(loaded.segments.count == 3)

        var segments = loaded.segments
        guard case .prose = segments[0].content else {
            Issue.record("expected prose first"); return
        }
        segments[0] = NotebookSegment(id: segments[0].id, content: .prose("rewritten"))
        let passageRaw = try #require({
            if case .passage(let p) = segments[1].content { return p.raw }
            return nil
        }())

        _ = try harness.library.saveNotebook(id: "baaaaaaaaa", segments: segments)
        let after = try harness.body(ofFile: fileName)
        #expect(after.hasPrefix("rewritten"))
        #expect(after.contains(passageRaw))
        #expect(after.hasSuffix("\n\nsecond paragraph"))
    }

    @Test("an unknown frontmatter key survives a save verbatim")
    func unknownFrontmatterKeyKept() throws {
        let harness = try Harness()
        try Files.createDirectory(harness.notebooksDir)
        try Files.write(
            """
            ---
            id: baaaaaaaaa
            title: 'Keys'
            created_at: 2026-09-29T10:00:00Z
            updated_at: 2026-09-29T10:00:00Z
            custom_field: keep me
            ---

            body text.
            """,
            to: harness.notebooksDir.appendingPathComponent("keys.md")
        )
        let loaded = try harness.library.notebook(id: "baaaaaaaaa")
        _ = try harness.library.saveNotebook(id: "baaaaaaaaa", segments: loaded.segments)
        let raw = try Files.read(harness.notebooksDir.appendingPathComponent("keys.md"))
        #expect(raw.contains("custom_field: keep me"))
        #expect(raw.contains("title: 'Keys'"))
    }

    // MARK: Passages

    /// A mark on chapter 001 of the fixture book.
    private func makeMark(
        _ harness: Harness, cfi: String? = "epubcfi(/6/2!/4/2)",
        quote: String = "a quote", body: String = ""
    ) throws -> Mark {
        try Notes.appendMark(
            bookDir: harness.library.bookDir(harness.bookID),
            chapter: harness.chapters[0],
            cfi: cfi, percent: 12.5, quote: quote, body: body
        )
    }

    @Test("addPassage from a selection creates the mark, the block, and the commentary")
    func addPassageSelection() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "Self-deception")

        let notebook = try harness.library.addPassage(
            notebookId: summary.id,
            source: .selection(
                bookId: harness.bookID, chapterKey: "001",
                cfi: "epubcfi(/6/2!/4/2)", percent: 12.5,
                quote: "Above all, don't lie to yourself"
            ),
            commentary: "the opening question"
        )

        // The mark landed in the chapter's note file.
        let note = try Notes.loadChapterNote(
            bookDir: harness.library.bookDir(harness.bookID), chapterKey: "001")
        #expect(note.marks.count == 1)
        let mark = note.marks[0]
        #expect(mark.quote == "Above all, don't lie to yourself")
        #expect(mark.cfi == "epubcfi(/6/2!/4/2)")

        // The file carries the canonical block and the commentary prose.
        let raw = try Files.read(
            harness.notebooksDir.appendingPathComponent(summary.file))
        #expect(
            raw.contains(
                "<!-- margins:passage book=\(harness.bookID) chapter=001 mark=\(mark.id) -->"))
        #expect(raw.contains("> Above all, don't lie to yourself\n"))
        #expect(raw.contains("> — Test Author, *Sample Book*, Introduction"))
        #expect(raw.hasSuffix("the opening question\n"))

        // Reloaded: resolved ok with book metadata.
        let loaded = try harness.library.notebook(id: summary.id)
        let passages = loaded.segments.compactMap { segment -> NotebookPassage? in
            guard case .passage(let passage) = segment.content else { return nil }
            return passage
        }
        #expect(passages.count == 1)
        #expect(passages[0].resolution.status == .ok)
        #expect(passages[0].resolution.quote == "Above all, don't lie to yourself")
        #expect(passages[0].resolution.bookTitle == "Sample Book")
        #expect(passages[0].resolution.cfi == "epubcfi(/6/2!/4/2)")
        #expect(loaded.summary.passageCount == 1)
        _ = notebook
    }

    @Test("a selection with the same cfi reuses the existing mark")
    func selectionReusesMarkByCFI() throws {
        let harness = try Harness()
        let mark = try makeMark(harness)
        let summary = try harness.library.createNotebook(title: "N")

        let notebook = try harness.library.addPassage(
            notebookId: summary.id,
            source: .selection(
                bookId: harness.bookID, chapterKey: "001",
                cfi: mark.cfi, percent: nil, quote: "different quote text"
            ),
            commentary: ""
        )

        let note = try Notes.loadChapterNote(
            bookDir: harness.library.bookDir(harness.bookID), chapterKey: "001")
        #expect(note.marks.count == 1, "the mark was reused, not duplicated")
        guard case .passage(let passage) = notebook.segments.last?.content else {
            Issue.record("expected a trailing passage"); return
        }
        #expect(passage.ref.markId == mark.id)
    }

    @Test("a selection without a cfi reuses a mark by its quote")
    func selectionReusesMarkByQuote() throws {
        let harness = try Harness()
        let mark = try makeMark(harness, cfi: nil, quote: "the same words")
        let summary = try harness.library.createNotebook(title: "N")

        let notebook = try harness.library.addPassage(
            notebookId: summary.id,
            source: .selection(
                bookId: harness.bookID, chapterKey: "001",
                cfi: nil, percent: nil, quote: "the same words"
            ),
            commentary: ""
        )
        guard case .passage(let passage) = notebook.segments.last?.content else {
            Issue.record("expected a trailing passage"); return
        }
        #expect(passage.ref.markId == mark.id)
        #expect(try Notes.loadChapterNote(
            bookDir: harness.library.bookDir(harness.bookID), chapterKey: "001"
        ).marks.count == 1)
    }

    @Test("addPassage from an existing mark embeds it directly")
    func addPassageMark() throws {
        let harness = try Harness()
        let mark = try makeMark(harness, body: "a thought")
        let summary = try harness.library.createNotebook(title: "N")

        let notebook = try harness.library.addPassage(
            notebookId: summary.id,
            source: .mark(bookId: harness.bookID, chapterKey: "001", markId: mark.id),
            commentary: ""
        )
        guard case .passage(let passage) = notebook.segments.last?.content else {
            Issue.record("expected a trailing passage"); return
        }
        #expect(passage.ref.markId == mark.id)
        #expect(passage.resolution.status == .ok)
        // The quote fell back to the body (the mark's quote is empty here
        // only when quote was empty — ours isn't).
        #expect(passage.resolution.quote == "a quote")
    }

    @Test("a new passage block pads itself to a blank line")
    func newPassagePadsToBlankLine() throws {
        let harness = try Harness()
        let mark = try makeMark(harness)
        // A prose-only body that ends without a trailing blank line.
        let fileName = try harness.writeNotebook(
            id: "baaaaaaaaa", title: "Padded", body: "ends flat")
        _ = try harness.library.addPassage(
            notebookId: "baaaaaaaaa",
            source: .mark(bookId: harness.bookID, chapterKey: "001", markId: mark.id),
            commentary: ""
        )
        let after = try harness.body(ofFile: fileName)
        #expect(after.hasPrefix("ends flat\n\n<!-- margins:passage"))
    }

    @Test("a deleted mark resolves mark-missing, keeps the cached quote, and saves verbatim")
    func markMissing() throws {
        let harness = try Harness()
        let mark = try makeMark(harness, quote: "the gone passage")
        let summary = try harness.library.createNotebook(title: "N")
        _ = try harness.library.addPassage(
            notebookId: summary.id,
            source: .mark(bookId: harness.bookID, chapterKey: "001", markId: mark.id),
            commentary: "before it vanished"
        )
        let fileName = summary.file
        let bodyBefore = try harness.body(ofFile: fileName)

        try Notes.deleteMark(
            bookDir: harness.library.bookDir(harness.bookID),
            chapter: harness.chapters[0], id: mark.id
        )

        let loaded = try harness.library.notebook(id: summary.id)
        guard case .passage(let passage) = loaded.segments.first?.content else {
            Issue.record("expected a leading passage"); return
        }
        #expect(passage.resolution.status == .markMissing)
        #expect(passage.resolution.quote == "the gone passage")
        #expect(passage.resolution.bookTitle == "Sample Book")

        // An unresolved block is never rewritten.
        _ = try harness.library.saveNotebook(id: summary.id, segments: loaded.segments)
        #expect(try harness.body(ofFile: fileName) == bodyBefore)
    }

    @Test("a removed book resolves book-missing")
    func bookMissing() throws {
        let harness = try Harness()
        let mark = try makeMark(harness)
        let summary = try harness.library.createNotebook(title: "N")
        _ = try harness.library.addPassage(
            notebookId: summary.id,
            source: .mark(bookId: harness.bookID, chapterKey: "001", markId: mark.id),
            commentary: ""
        )
        try harness.library.removeBook(id: harness.bookID)

        let loaded = try harness.library.notebook(id: summary.id)
        guard case .passage(let passage) = loaded.segments.first?.content else {
            Issue.record("expected a leading passage"); return
        }
        #expect(passage.resolution.status == .bookMissing)
        #expect(passage.resolution.quote == "a quote")
    }

    @Test("a changed mark quote refreshes only its own block")
    func quoteChangeRewritesBlock() throws {
        let harness = try Harness()
        let mark = try makeMark(harness, quote: "the old words")
        let summary = try harness.library.createNotebook(title: "N")
        _ = try harness.library.addPassage(
            notebookId: summary.id,
            source: .mark(bookId: harness.bookID, chapterKey: "001", markId: mark.id),
            commentary: "unchanged prose"
        )
        let fileName = summary.file

        var edited = mark
        edited.quote = "the new words"
        try Notes.updateMark(
            bookDir: harness.library.bookDir(harness.bookID),
            chapter: harness.chapters[0], mark: edited
        )

        // Load shows the live quote.
        let loaded = try harness.library.notebook(id: summary.id)
        guard case .passage(let passage) = loaded.segments.first?.content else {
            Issue.record("expected a leading passage"); return
        }
        #expect(passage.resolution.quote == "the new words")
        #expect(passage.cachedQuote == "the old words")

        // Save rewrites just the block; the prose keeps its bytes.
        _ = try harness.library.saveNotebook(id: summary.id, segments: loaded.segments)
        let after = try harness.body(ofFile: fileName)
        #expect(after.contains("> the new words"))
        #expect(!after.contains("> the old words"))
        #expect(after.contains("unchanged prose"))
        #expect(after.contains("> — Test Author, *Sample Book*, Introduction"))
    }

    // MARK: Index reconciliation

    @Test("an externally added .md file joins the listing and the index")
    func externalFileJoinsIndex() throws {
        let harness = try Harness()
        _ = try harness.library.createNotebook(title: "Known")
        try harness.writeNotebook(id: "bbbbbbbbbb", title: "External", body: "hi\n")

        let list = try harness.library.listNotebooks()
        #expect(list.count == 2)
        #expect(list.contains { $0.id == "bbbbbbbbbb" })

        let index = try MarginsJSON.decode(
            NotebooksIndex.self,
            from: Files.readData(harness.notebooksDir.appendingPathComponent("_index.json"))
        )
        // Index rebuilt from files: both ids present.
        #expect(index.notebooks.map(\.id).sorted().contains("bbbbbbbbbb"))
        #expect(index.notebooks.count == 2)
    }

    @Test("an externally deleted file drops out of the listing")
    func externalFileDropsOut() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "Gone")
        // Warm the index.
        #expect(try harness.library.listNotebooks().count == 1)
        try Files.remove(harness.notebooksDir.appendingPathComponent(summary.file))

        #expect(try harness.library.listNotebooks().isEmpty)
        let index = try MarginsJSON.decode(
            NotebooksIndex.self,
            from: Files.readData(harness.notebooksDir.appendingPathComponent("_index.json"))
        )
        #expect(index.notebooks.isEmpty)
    }

    @Test("addPassage from an unknown mark, chapter, or book is an error")
    func addPassageValidation() throws {
        let harness = try Harness()
        let summary = try harness.library.createNotebook(title: "N")
        #expect(throws: CoreError.self) {
            try harness.library.addPassage(
                notebookId: summary.id,
                source: .mark(bookId: harness.bookID, chapterKey: "001", markId: "zzzzzzzzzz"),
                commentary: ""
            )
        }
        #expect(throws: CoreError.self) {
            try harness.library.addPassage(
                notebookId: summary.id,
                source: .mark(bookId: harness.bookID, chapterKey: "999", markId: "zzzzzzzzzz"),
                commentary: ""
            )
        }
        #expect(throws: CoreError.self) {
            try harness.library.addPassage(
                notebookId: summary.id,
                source: .mark(bookId: "nosuchbook", chapterKey: "001", markId: "zzzzzzzzzz"),
                commentary: ""
            )
        }
        // A selection into an unknown chapter fails the same way.
        #expect(throws: CoreError.self) {
            try harness.library.addPassage(
                notebookId: summary.id,
                source: .selection(
                    bookId: harness.bookID, chapterKey: "999",
                    cfi: nil, percent: nil, quote: "q"
                ),
                commentary: ""
            )
        }
    }

    // MARK: iCloud eviction

    /// A library rooted inside a fake ubiquity container, so `FileStore`
    /// takes the coordinated branch and `.{name}.icloud` files are
    /// placeholders rather than plain files.
    private func containerLibrary() throws -> (documents: URL, library: Library) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-nb-icloud-\(UUID().uuidString)", isDirectory: true)
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        FileStore.overrideContainerProvider { documents }
        return (documents, try Library(root: documents.appendingPathComponent("library").path))
    }

    /// Replaces `file` with its `.{file}.icloud` placeholder — the on-disk
    /// shape of an evicted ubiquitous item.
    private func evict(_ file: String, in dir: String) throws {
        try Files.remove(dir.appendingPathComponent(file))
        try Files.write("placeholder", to: dir.appendingPathComponent(".\(file).icloud"))
    }

    @Test("an evicted notebook keeps its index entry, is flagged, and refuses loads")
    func evictedNotebook() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let (documents, library) = try containerLibrary()
        let one = try library.createNotebook(title: "One")
        let two = try library.createNotebook(title: "Two")
        let notebooksDir = documents.appendingPathComponent("library/notebooks").path
        let indexPath = notebooksDir.appendingPathComponent("_index.json")
        let indexBytes = try Files.readData(indexPath)

        try evict(one.file, in: notebooksDir)

        // Both notebooks still list; the evicted one is flagged, the index
        // is byte-identical (the placeholder keeps its synced entry).
        var list = try library.listNotebooks()
        #expect(list.count == 2)
        #expect(list.first { $0.id == one.id }?.isEvicted == true)
        #expect(list.first { $0.id == two.id }?.isEvicted == false)
        #expect(try Files.readData(indexPath) == indexBytes)

        // A rebuild triggered by an external file keeps the evicted
        // file's synced entry instead of dropping it.
        try Files.write(
            """
            ---
            id: bbbbbbbbbb
            title: 'External'
            created_at: 2026-09-29T10:00:00Z
            updated_at: 2026-09-29T10:00:00Z
            ---

            """,
            to: notebooksDir.appendingPathComponent("external.md")
        )
        list = try library.listNotebooks()
        #expect(list.count == 3)
        #expect(list.first { $0.id == one.id }?.isEvicted == true)
        let index = try MarginsJSON.decode(
            NotebooksIndex.self, from: Files.readData(indexPath))
        #expect(index.notebooks.contains { $0.id == one.id })
        #expect(index.notebooks.contains { $0.id == "bbbbbbbbbb" })

        // Loading the evicted notebook fails fast with notDownloaded.
        let evictedPath = notebooksDir.appendingPathComponent(one.file)
        do {
            _ = try library.notebook(id: one.id)
            Issue.record("expected an evicted load to throw")
        } catch let error as CoreError {
            #expect(error == .notDownloaded(evictedPath))
        } catch {
            Issue.record("expected CoreError, got \(error)")
        }
        // Saving is refused the same way.
        #expect(throws: CoreError.self) {
            try library.saveNotebook(id: one.id, segments: [])
        }
    }

    @Test("a placeholder with no index entry does not rewrite the index")
    func evictedWithoutEntryDoesNotRewriteIndex() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let (documents, library) = try containerLibrary()
        let one = try library.createNotebook(title: "One")
        let notebooksDir = documents.appendingPathComponent("library/notebooks").path
        let indexPath = notebooksDir.appendingPathComponent("_index.json")

        // A placeholder for a notebook this device never indexed — files
        // and index entries disagree on every listing, so a naive rebuild
        // would rewrite identical bytes forever.
        try Files.write(
            "placeholder",
            to: notebooksDir.appendingPathComponent(".ghost.md.icloud"))
        let bytesBefore = try Files.readData(indexPath)
        let mtimeBefore = Files.modificationDate(indexPath)

        _ = try library.listNotebooks()
        _ = try library.listNotebooks()

        #expect(try Files.readData(indexPath) == bytesBefore)
        #expect(Files.modificationDate(indexPath) == mtimeBefore)
        #expect(try library.listNotebooks().map(\.id) == [one.id])
    }

    @Test("an evicted index lists downloaded files and is never rewritten")
    func evictedIndex() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let (documents, library) = try containerLibrary()
        let one = try library.createNotebook(title: "One")
        let two = try library.createNotebook(title: "Two")
        let notebooksDir = documents.appendingPathComponent("library/notebooks").path
        let indexPath = notebooksDir.appendingPathComponent("_index.json")
        let indexPlaceholder = notebooksDir.appendingPathComponent("._index.json.icloud")

        try evict("_index.json", in: notebooksDir)
        try evict(two.file, in: notebooksDir)

        // Best-effort listing: the downloaded notebook parses, the evicted
        // one has no index entry to fall back on and is omitted.
        let list = try library.listNotebooks()
        #expect(list.map(\.id) == [one.id])

        // The index placeholder survives — nothing rewrote it.
        #expect(!Files.exists(indexPath))
        #expect(Files.exists(indexPlaceholder))
    }

    // MARK: Reverse lookup

    @Test("notebooksCiting maps a mark to its notebooks")
    func reverseLookup() throws {
        let harness = try Harness()
        let mark = try makeMark(harness)
        let first = try harness.library.createNotebook(title: "First")
        let second = try harness.library.createNotebook(title: "Second")
        for summary in [first, second] {
            _ = try harness.library.addPassage(
                notebookId: summary.id,
                source: .mark(bookId: harness.bookID, chapterKey: "001", markId: mark.id),
                commentary: ""
            )
        }

        let citing = try harness.library.notebooksCiting(bookId: harness.bookID)
        #expect(citing[mark.id]?.map(\.id).sorted() == [first.id, second.id].sorted())
        // A book nobody cites is simply absent.
        #expect(citing["zzzzzzzzzz"] == nil)
    }
}
