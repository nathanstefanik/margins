import Foundation
@testable import MarginsCore
import Testing

/// Translated from the legacy core's library test module. The
/// recurring concern is that a book directory is either whole or absent: an
/// interrupted import must not surface as a book, and a repair must not
/// destroy the source it is repairing from.
@Suite("Library")
struct LibraryTests {
    private struct Harness {
        let root: URL
        let library: Library

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("margins-library-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try Library(root: root.appendingPathComponent("library").path)
        }

        func epub(
            _ name: String = "sample.epub",
            cover: EpubFixtureBuilder.SampleCover = .none,
            toc: EpubFixtureBuilder.SampleTOC = .none
        ) throws -> String {
            try EpubFixtureBuilder.sampleEpub(in: root, named: name, cover: cover, toc: toc)
        }
    }

    /// Rewrites a book's `meta.json` the way a pre-TOC import left it: no
    /// `chapters_version`, no fragments, titles from `<title>`, and none of
    /// the v2 outline fields.
    private func downgradeChapters(bookDir: String) throws {
        let path = bookDir.appendingPathComponent("meta.json")
        var meta = try MarginsJSON.decode(BookMeta.self, from: Files.readData(path))
        meta.chaptersVersion = 0
        meta.chapters = meta.chapters.enumerated().map { index, chapter in
            var chapter = chapter
            chapter.fragment = nil
            chapter.title = "Chapter \(index + 1)"
            chapter.matter = .body
            chapter.level = 0
            chapter.sections = []
            return chapter
        }
        // Written as the old core would have: absent version and outline
        // keys entirely.
        var object = try #require(
            try JSONSerialization.jsonObject(with: MarginsJSON.encode(meta)) as? [String: Any]
        )
        object.removeValue(forKey: "chapters_version")
        if var chapters = object["chapters"] as? [[String: Any]] {
            for index in chapters.indices {
                chapters[index].removeValue(forKey: "matter")
                chapters[index].removeValue(forKey: "level")
                chapters[index].removeValue(forKey: "sections")
            }
            object["chapters"] = chapters
        }
        try Files.writeData(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]), to: path
        )
    }

    // MARK: Covers

    @Test("import stores the cover and reports it in the catalog")
    func importStoresTheCover() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(
            atPath: harness.epub("covered.epub", cover: .epub3)
        )
        #expect(meta.cover == "cover.png")
        // The absolute path is resolved for callers but never persisted.
        #expect(meta.coverPath?.hasSuffix("cover.png") == true)

        let coverPath = harness.library.bookDir(meta.id).appendingPathComponent("cover.png")
        #expect(try Files.readData(coverPath) == EpubFixtureBuilder.sampleCoverPNG)

        #expect(try harness.library.listBooks()[0].cover == "cover.png")
        #expect(try harness.library.getBook(id: meta.id).cover == "cover.png")

        let index = try Files.read(
            harness.root.appendingPathComponent("library/index.json").path
        )
        #expect(index.contains("\"cover\" : \"cover.png\""))
    }

    @Test("a book with no cover imports with a null cover")
    func importWithoutCover() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub("plain.epub"))
        #expect(meta.cover == nil)
        #expect(meta.coverPath == nil)
        #expect(try harness.library.listBooks()[0].cover == nil)
    }

    @Test("the catalog skips books whose metadata is evicted")
    func catalogSkipsEvictedMetadata() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-library-evicted-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documents, withIntermediateDirectories: true
        )
        FileStore.overrideContainerProvider { documents }

        let library = try Library(root: documents.appendingPathComponent("Library").path)
        let epub = try EpubFixtureBuilder.sampleEpub(in: documents, named: "available.epub")
        let available = try library.importEpub(atPath: epub)

        let evictedID = "evicted-book"
        let evictedDir = library.bookDir(evictedID)
        try Files.createDirectory(evictedDir)
        let placeholder = evictedDir.appendingPathComponent(".meta.json.icloud")
        try Files.write("placeholder", to: placeholder)

        let listed = try library.listBooks()
        #expect(listed.map(\.id) == [available.id])
        #expect(library.notDownloadedBookIDs() == [evictedID])

        let index = try MarginsJSON.decode(
            LibraryIndex.self,
            from: Files.readData(documents.appendingPathComponent("Library/index.json").path)
        )
        #expect(index.books.map(\.id) == [available.id])

        try Files.remove(placeholder)
        try Files.write("not json", to: evictedDir.appendingPathComponent("meta.json"))
        #expect(throws: CoreError.self) {
            try library.listBooks()
        }
    }

    @Test("the scan backfills covers for books imported before extraction existed")
    func scanBackfillsCovers() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(
            atPath: harness.epub("legacy.epub", cover: .epub3)
        )
        let bookDir = harness.library.bookDir(meta.id)

        // Simulate a book imported before cover extraction existed.
        var stored = try MarginsJSON.decode(
            BookMeta.self, from: Files.readData(bookDir.appendingPathComponent("meta.json"))
        )
        stored.cover = nil
        try Files.writeData(
            MarginsJSON.encode(stored), to: bookDir.appendingPathComponent("meta.json")
        )
        try Files.remove(bookDir.appendingPathComponent("cover.png"))

        // The next scan extracts the cover again and persists it.
        #expect(try harness.library.listBooks()[0].cover == "cover.png")
        #expect(
            try Files.readData(bookDir.appendingPathComponent("cover.png"))
                == EpubFixtureBuilder.sampleCoverPNG
        )
        #expect(try harness.library.getBook(id: meta.id).cover == "cover.png")

        // ... and a follow-up scan does not duplicate or drop it.
        #expect(try harness.library.listBooks()[0].cover == "cover.png")
    }

    @Test("a corrupt source does not fail the scan")
    func corruptSourceToleratedWhenBackfilling() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub("plain.epub"))
        try Files.write(
            "junk", to: harness.library.bookDir(meta.id).appendingPathComponent("source.epub")
        )

        let listed = try harness.library.listBooks()
        #expect(listed.count == 1)
        #expect(listed[0].cover == nil)
    }

    // MARK: Chapter metadata upgrades

    @Test("the scan upgrades legacy chapter metadata without moving keys")
    func scanUpgradesChapterMetadata() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub("legacy.epub", toc: .ncx))
        let bookDir = harness.library.bookDir(meta.id)

        // A note written before the upgrade, keyed by spine position.
        let chapter = meta.chapters[0]
        try Notes.saveChapterNote(
            bookDir: bookDir,
            chapter: chapter,
            frontmatter: NoteFrontmatter(
                bookId: meta.id, chapterKey: chapter.key, chapterIndex: chapter.index,
                chapterTitle: "Chapter 1", chapterHref: chapter.href, kind: "summary", wordCount: 0
            ),
            body: "Notes from before the upgrade."
        )

        try downgradeChapters(bookDir: bookDir)
        _ = try harness.library.listBooks()

        let upgraded = try harness.library.getBook(id: meta.id)
        #expect(upgraded.chaptersVersion == Library.chaptersVersion)
        #expect(upgraded.chaptersVersion == 2)
        #expect(upgraded.chapters[0].key == "001")
        #expect(upgraded.chapters[0].title == "Opening Remarks")
        #expect(upgraded.chapters[0].fragment == "start")
        // v2 fields: matter classified and every TOC entry kept as a section.
        #expect(upgraded.chapters[0].matter == .body)
        #expect(upgraded.chapters[0].level == 0)
        #expect(
            upgraded.chapters[0].sections
                == [
                    ChapterSection(title: "Opening Remarks", fragment: "start", level: 0),
                    ChapterSection(title: "A Nested Aside", fragment: "aside", level: 1),
                ]
        )

        // The note still resolves under the same key, body intact.
        #expect(
            try Notes.loadChapterNote(bookDir: bookDir, chapterKey: "001").body
                == "Notes from before the upgrade."
        )

        // A second scan is a no-op: the version stops the re-parse.
        _ = try harness.library.listBooks()
        #expect(try harness.library.getBook(id: meta.id).chapters[0].title == "Opening Remarks")
    }

    @Test("the scan leaves chapters alone when the source is unreadable")
    func scanLeavesChaptersAloneWhenSourceIsBad() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub("legacy.epub", toc: .ncx))
        let bookDir = harness.library.bookDir(meta.id)

        try downgradeChapters(bookDir: bookDir)
        try Files.write("junk", to: bookDir.appendingPathComponent("source.epub"))

        #expect(try harness.library.listBooks().count == 1)
        let unchanged = try harness.library.getBook(id: meta.id)
        #expect(unchanged.chaptersVersion == 0)
        #expect(unchanged.chapters[0].title == "Chapter 1")
        #expect(unchanged.chapters.count == 2)
    }

    // MARK: Reading position

    @Test("a reading position round-trips and clamps its percent")
    func positionRoundTripsAndClamps() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub())

        // Never opened: no position.
        #expect(harness.library.readPosition(bookID: meta.id) == nil)

        try harness.library.writePosition(
            bookID: meta.id,
            position: ReadingPosition(
                chapterKey: "002", epubCfi: "epubcfi(/6/4!/4/2)", percent: 42.5
            )
        )
        let read = try #require(harness.library.readPosition(bookID: meta.id))
        #expect(read.chapterKey == "002")
        #expect(read.epubCfi == "epubcfi(/6/4!/4/2)")
        #expect(read.percent == 42.5)
        // The save time is stamped by the core, not the caller.
        #expect(read.updatedAt != nil)

        try harness.library.writePosition(
            bookID: meta.id, position: ReadingPosition(chapterKey: "002", percent: 150)
        )
        #expect(harness.library.readPosition(bookID: meta.id)?.percent == 100)

        try harness.library.writePosition(
            bookID: meta.id, position: ReadingPosition(chapterKey: "001", percent: -5)
        )
        #expect(harness.library.readPosition(bookID: meta.id)?.percent == 0)

        // The catalog and the book detail join the percent through.
        #expect(try harness.library.listBooks()[0].progressPercent == 0)
        #expect(try harness.library.getBook(id: meta.id).progressPercent == 0)
    }

    @Test("a corrupt position file reads as never opened")
    func corruptPositionFallsBack() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub())
        try Files.write(
            "not json",
            to: harness.library.bookDir(meta.id).appendingPathComponent("position.json")
        )

        #expect(harness.library.readPosition(bookID: meta.id) == nil)
        #expect(try harness.library.listBooks()[0].progressPercent == nil)
        #expect(try harness.library.getBook(id: meta.id).progressPercent == nil)
    }

    // MARK: Bookmarks

    @Test("named bookmarks round-trip, clamp percent, and vanish with the last pin")
    func bookmarksRoundTrip() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub())
        #expect(harness.library.readBookmarks(bookID: meta.id).isEmpty)

        let first = try harness.library.addBookmark(
            bookID: meta.id,
            label: "  the interpolation  ",
            position: ReadingPosition(
                chapterKey: "002", epubCfi: "epubcfi(/6/4!/4/2)", percent: 61.2
            )
        )
        #expect(first.label == "the interpolation")
        #expect(first.epubCfi == "epubcfi(/6/4!/4/2)")

        let second = try harness.library.addBookmark(
            bookID: meta.id,
            label: "",
            position: ReadingPosition(chapterKey: "001", epubCfi: "", percent: 150)
        )
        #expect(second.label.isEmpty)
        #expect(second.epubCfi == nil)
        #expect(second.percent == 100)

        let listed = harness.library.readBookmarks(bookID: meta.id)
        #expect(listed.map(\.id) == [first.id, second.id])

        let renamed = try harness.library.updateBookmark(
            bookID: meta.id, id: first.id, label: "claim", position: nil
        )
        #expect(renamed.label == "claim")
        #expect(renamed.epubCfi == first.epubCfi)

        try harness.library.deleteBookmark(bookID: meta.id, id: first.id)
        try harness.library.deleteBookmark(bookID: meta.id, id: second.id)
        #expect(harness.library.readBookmarks(bookID: meta.id).isEmpty)
        #expect(
            !Files.exists(
                harness.library.bookDir(meta.id).appendingPathComponent("bookmarks.json")
            )
        )
    }

    @Test("a corrupt bookmarks file reads as none")
    func corruptBookmarksFallBack() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub())
        try Files.write(
            "not json",
            to: harness.library.bookDir(meta.id).appendingPathComponent("bookmarks.json")
        )
        #expect(harness.library.readBookmarks(bookID: meta.id).isEmpty)
    }

    @Test("adding a bookmark refuses to overwrite an evicted file")
    func addBookmarkRefusesEvictedFile() throws {
        FileStoreTestIsolation.begin()
        defer { FileStoreTestIsolation.end() }
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-bookmarks-evicted-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documents, withIntermediateDirectories: true
        )
        FileStore.overrideContainerProvider { documents }

        let library = try Library(root: documents.appendingPathComponent("Library").path)
        let epub = try EpubFixtureBuilder.sampleEpub(in: documents, named: "book.epub")
        let book = try library.importEpub(atPath: epub)
        let path = library.bookDir(book.id).appendingPathComponent("bookmarks.json")
        let placeholder = library.bookDir(book.id).appendingPathComponent(".bookmarks.json.icloud")
        try Files.write("placeholder", to: placeholder)

        do {
            _ = try library.addBookmark(
                bookID: book.id,
                label: "saved place",
                position: ReadingPosition(chapterKey: "001", percent: 12.5)
            )
            Issue.record("expected an evicted bookmarks file to refuse the write")
        } catch let error as CoreError {
            #expect(error == .notDownloaded(path))
        } catch {
            Issue.record("expected CoreError, got \(error)")
        }
        #expect(!Files.exists(path))
        #expect(Files.exists(placeholder))
    }

    // MARK: Import lifecycle

    @Test("import, list, get, and remove round-trip")
    func importListGetRemove() throws {
        let harness = try Harness()
        let epub = try harness.epub()

        let meta = try harness.library.importEpub(atPath: epub)
        #expect(meta.title == "Sample Book")
        #expect(meta.chapters.count == 2)
        let bookDir = harness.library.bookDir(meta.id)
        #expect(Files.exists(bookDir.appendingPathComponent("source.epub")))
        #expect(Files.exists(bookDir.appendingPathComponent("notes/_index.json")))
        #expect(Files.exists(bookDir.appendingPathComponent("README.md")))

        // Importing the same file again is idempotent: same content, same id.
        #expect(try harness.library.importEpub(atPath: epub).id == meta.id)

        let listed = try harness.library.listBooks()
        #expect(listed.count == 1)
        #expect(listed[0].id == meta.id)
        #expect(listed[0].notesCount == 0)
        #expect(Files.exists(harness.root.appendingPathComponent("library/index.json").path))
        #expect(try !harness.library.readEpubBytes(bookID: meta.id).isEmpty)

        try harness.library.removeBook(id: meta.id)
        #expect(try harness.library.listBooks().isEmpty)
        #expect(!Files.exists(bookDir))
    }

    @Test("import reports monotonic progress")
    func importReportsMonotonicProgress() throws {
        let harness = try Harness()
        var updates: [(Int, String)] = []
        try harness.library.importEpub(atPath: harness.epub()) { percent, stage in
            updates.append((percent, stage))
        }

        #expect(updates.first?.0 == 0)
        #expect(updates.first?.1 == "preparing")
        #expect(updates.last?.0 == 100)
        #expect(updates.last?.1 == "complete")
        #expect(updates.contains { $0.1 == "hashing" })
        #expect(updates.contains { $0.1 == "copying" })
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $1.0 >= $0.0 })
    }

    @Test("a failed import can be retried without leaving a partial book")
    func failedImportCanBeRetried() throws {
        let harness = try Harness()
        let epub = try harness.epub()
        let original = try Files.readData(epub)
        var failedOnce = false

        #expect(throws: CoreError.self) {
            try harness.library.importEpub(atPath: epub) { _, stage in
                if stage == "copying", !failedOnce {
                    failedOnce = true
                    try? Files.remove(epub)
                }
            }
        }
        // No staging directory survives the failure.
        let entries = try Files.contents(
            ofDirectory: harness.root.appendingPathComponent("library/books").path
        )
        #expect(entries.isEmpty)

        try Files.writeData(original, to: epub)
        #expect(try harness.library.importEpub(atPath: epub).title == "Sample Book")
    }

    @Test("repairing an incomplete book does not delete its source")
    func repairDoesNotDeleteTheSource() throws {
        let harness = try Harness()
        let epub = try harness.epub()
        let bookID = try hashFile(epub) { _, _ in }
        let partial = harness.library.bookDir(bookID)
        try Files.createDirectory(partial)
        try Files.writeData(
            Files.readData(epub), to: partial.appendingPathComponent("source.epub")
        )

        // Importing from inside the incomplete directory: the final
        // directory is only removed after the source is safely in staging.
        let repaired = try harness.library.importEpub(
            atPath: partial.appendingPathComponent("source.epub")
        )
        #expect(repaired.id == bookID)
        #expect(Files.isFile(partial.appendingPathComponent("source.epub")))
    }

    @Test("the scan ignores interrupted import staging directories")
    func scanIgnoresStagingDirectories() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub())
        let staging = harness.root
            .appendingPathComponent("library/books/.\(meta.id).importing-crashed").path
        try Files.createDirectory(staging)
        try Files.writeData(
            Files.readData(harness.library.bookDir(meta.id).appendingPathComponent("meta.json")),
            to: staging.appendingPathComponent("meta.json")
        )

        let listed = try harness.library.listBooks()
        #expect(listed.count == 1)
        #expect(listed[0].id == meta.id)
    }

    @Test("a failed duplicate import does not report completion")
    func failedDuplicateImportDoesNotComplete() throws {
        let harness = try Harness()
        let epub = try harness.epub()
        let meta = try harness.library.importEpub(atPath: epub)
        try Files.write(
            "not json",
            to: harness.library.bookDir(meta.id).appendingPathComponent("meta.json")
        )

        var updates: [(Int, String)] = []
        #expect(throws: CoreError.self) {
            try harness.library.importEpub(atPath: epub) { updates.append(($0, $1)) }
        }
        #expect(!updates.contains { $0.0 == 100 })
    }

    @Test("re-importing repairs a missing source file")
    func reimportRepairsMissingSource() throws {
        let harness = try Harness()
        let epub = try harness.epub()
        let meta = try harness.library.importEpub(atPath: epub)
        try Files.remove(
            harness.library.bookDir(meta.id).appendingPathComponent("source.epub")
        )

        try harness.library.importEpub(atPath: epub)
        #expect(Files.isFile(
            harness.library.bookDir(meta.id).appendingPathComponent("source.epub")
        ))
    }

    @Test("setting the root switches the active library")
    func setRootSwitchesLibrary() throws {
        let harness = try Harness()
        let meta = try harness.library.importEpub(atPath: harness.epub())
        #expect(try harness.library.listBooks().count == 1)

        try harness.library.setRoot(harness.root.appendingPathComponent("b").path)
        #expect(try harness.library.listBooks().isEmpty)
        #expect(!Files.exists(harness.library.bookDir(meta.id)))
    }

    // MARK: Book ids

    @Test("the book id is the EPUB's content hash, 24 hex characters")
    func bookIDIsAContentHash() throws {
        let harness = try Harness()
        let epub = try harness.epub()
        let id = try hashFile(epub) { _, _ in }
        #expect(id.count == 24)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        // Same bytes at a different path, same id: that is what makes a
        // re-import idempotent.
        let copy = harness.root.appendingPathComponent("elsewhere.epub").path
        try Files.writeData(Files.readData(epub), to: copy)
        #expect(try hashFile(copy) { _, _ in } == id)
    }
}
