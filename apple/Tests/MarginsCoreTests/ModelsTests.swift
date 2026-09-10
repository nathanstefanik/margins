import Foundation
import MarginsCore
import Testing

/// The model layer's on-disk contract (docs/apple-only-plan.md Phase 2
/// step 2). The Swift core has to read libraries the Rust core wrote and
/// write files the Rust core would accept, so these tests pin coding keys,
/// serde's defaults and omissions, and the timestamp format rather than
/// merely round-tripping Swift values through Swift.
@Suite("Models")
struct ModelsTests {
    // MARK: Timestamps

    @Test("RFC3339 parses every fractional width chrono emits, and drops a zero fraction")
    func parsesEveryFractionalWidth() throws {
        // chrono serializes with SecondsFormat::AutoSi, which trims trailing
        // zeros to 0, 3, 6, or 9 digits, so all four widths exist on disk.
        let widths = [
            "2026-09-05T14:02:11Z",
            "2026-09-05T14:02:11.000Z",
            "2026-09-05T14:02:11.000000Z",
            "2026-09-05T14:02:11.000000000Z",
        ]
        for raw in widths {
            let date = try #require(RFC3339.date(from: raw), "could not parse \(raw)")
            #expect(RFC3339.string(from: date) == "2026-09-05T14:02:11Z")
        }
    }

    @Test("RFC3339 keeps millisecond precision and reads a numeric offset")
    func keepsMillisecondsAndOffsets() throws {
        let millis = try #require(RFC3339.date(from: "2026-09-05T14:02:11.123456789Z"))
        #expect(RFC3339.string(from: millis) == "2026-09-05T14:02:11.123Z")

        // `to_rfc3339()` — what the UniFFI bridge handed the apps — wrote a
        // numeric offset instead of `Z`.
        let offset = try #require(RFC3339.date(from: "2026-09-05T16:02:11+02:00"))
        #expect(RFC3339.string(from: offset) == "2026-09-05T14:02:11Z")
    }

    @Test("RFC3339 rejects text that is not a timestamp")
    func rejectsGarbage() {
        #expect(RFC3339.date(from: "") == nil)
        #expect(RFC3339.date(from: "yesterday") == nil)
        #expect(RFC3339.date(from: "2026-09-05") == nil)
    }

    @Test("the codec is a fixed point across the millisecond range")
    func codecIsAFixedPoint() throws {
        // `Date`'s binary fraction is not the decimal one, so a naive
        // format/parse pair drifts by a millisecond for roughly half of all
        // instants — which showed up as a note's stamped `created_at` not
        // comparing equal to the same value read back. Sweep a full second
        // at millisecond resolution, plus the stamping helper.
        for millisecond in 0..<1000 {
            let encoded = millisecond == 0
                ? "2026-09-05T14:02:11Z"
                : String(format: "2026-09-05T14:02:11.%03dZ", millisecond)
            let decoded = try #require(RFC3339.date(from: encoded))
            #expect(RFC3339.string(from: decoded) == encoded)
            #expect(RFC3339.date(from: RFC3339.string(from: decoded)) == decoded)
        }
        // And the value the core stamps onto a save survives its own trip.
        let stamped = RFC3339.now()
        #expect(RFC3339.date(from: RFC3339.string(from: stamped)) == stamped)
    }

    @Test("a timestamp that survives the trip encodes back to itself")
    func timestampsRoundTrip() throws {
        let raw = "2026-08-29T12:30:00.250Z"
        let date = try #require(RFC3339.date(from: raw))
        #expect(RFC3339.string(from: date) == raw)
    }

    // MARK: meta.json

    @Test("meta.json written by the Rust core decodes")
    func decodesRustMetaJson() throws {
        let meta = try MarginsJSON.decode(BookMeta.self, from: Data(Self.metaJSON.utf8))

        #expect(meta.id == "a1b2c3d4e5f6a1b2c3d4e5f6")
        #expect(meta.title == "The Brothers Karamazov")
        #expect(meta.language == "en")
        #expect(meta.sourceFilename == "karamazov.epub")
        #expect(meta.cover == "cover.jpg")
        #expect(meta.chaptersVersion == 1)
        #expect(meta.addedAt == RFC3339.date(from: "2026-09-02T10:00:00Z"))
        #expect(meta.chapters.count == 2)
        #expect(meta.chapters[0].fragment == nil)
        #expect(meta.chapters[1].fragment == "pgepubid00008")
        // Resolved at call time from the library root, never read from disk.
        #expect(meta.coverPath == nil)
        #expect(meta.progressPercent == nil)
        // The v2 outline fields default for files written before them.
        #expect(meta.chapters[0].matter == .body)
        #expect(meta.chapters[0].level == 0)
        #expect(meta.chapters[0].sections.isEmpty)
    }

    @Test("the v2 outline fields round-trip through meta.json")
    func outlineFieldsRoundTrip() throws {
        var meta = try MarginsJSON.decode(BookMeta.self, from: Data(Self.metaJSON.utf8))
        meta.chapters[0].matter = .front
        meta.chapters[0].level = 1
        meta.chapters[0].sections = [
            ChapterSection(title: "Preface", fragment: "pref", level: 1),
            ChapterSection(title: "Acknowledgements", level: 2),
        ]
        let decoded = try MarginsJSON.decode(BookMeta.self, from: try MarginsJSON.encode(meta))
        #expect(decoded == meta)
        #expect(decoded.chapters[0].sections[1].fragment == nil)
    }

    @Test("meta.json re-encodes with serde's key order and omissions")
    func encodesMetaJsonLikeSerde() throws {
        let meta = try MarginsJSON.decode(BookMeta.self, from: Data(Self.metaJSON.utf8))
        var round = meta
        // A resolved cover path must never reach the file.
        round.coverPath = "/tmp/library/books/a1b2c3d4e5f6a1b2c3d4e5f6/cover.jpg"
        let encoded = String(decoding: try MarginsJSON.encode(round), as: UTF8.self)

        #expect(!encoded.contains("coverPath"))
        #expect(!encoded.contains("cover_path"))
        // `progress_percent` lives in position.json; serde skips it here.
        #expect(!encoded.contains("progress_percent"))
        #expect(Self.keyNames(encoded) == [
            "added_at", "author", "chapters", "chapters_version", "cover", "href",
            "href", "id", "index", "index", "key", "key", "language", "fragment",
            "source_filename", "title", "title", "title",
            "level", "level", "matter", "matter", "sections", "sections",
        ].sorted())
        // The values survive the trip; only the key order differs from what
        // serde wrote (see `MarginsJSON`).
        #expect(try MarginsJSON.decode(BookMeta.self, from: Data(encoded.utf8)) == meta)
    }

    @Test("a book imported before TOC titles existed reads as version 0")
    func chaptersVersionDefaultsToZero() throws {
        let legacy = """
        {
          "id": "old",
          "title": "Old",
          "author": "Anon",
          "language": null,
          "added_at": "2026-01-01T00:00:00Z",
          "source_filename": "old.epub",
          "chapters": []
        }
        """
        let meta = try MarginsJSON.decode(BookMeta.self, from: Data(legacy.utf8))
        #expect(meta.chaptersVersion == 0)
        #expect(meta.cover == nil)
        #expect(meta.language == nil)
    }

    @Test("a coverless book keeps an explicit null")
    func coverlessBookEncodesNull() throws {
        let meta = BookMeta(
            id: "x", title: "X", author: "Y",
            addedAt: Date(timeIntervalSince1970: 0),
            sourceFilename: "x.epub", chapters: []
        )
        let encoded = String(decoding: try MarginsJSON.encode(meta), as: UTF8.self)
        #expect(encoded.contains("\"cover\" : null"))
        #expect(encoded.contains("\"language\" : null"))
    }

    @Test("jumpTarget appends the TOC anchor only when the book named one")
    func jumpTargetUsesTheFragment() {
        let plain = ChapterMeta(key: "001", index: 0, title: "One", href: "one.xhtml")
        #expect(plain.jumpTarget == "one.xhtml")
        #expect(plain.id == "001")

        let anchored = ChapterMeta(
            key: "002", index: 1, title: "Two", href: "two.xhtml", fragment: "part-two"
        )
        #expect(anchored.jumpTarget == "two.xhtml#part-two")

        // An empty anchor is no anchor; `href` stays a pure path either way.
        let empty = ChapterMeta(key: "003", index: 2, title: "Three", href: "three.xhtml", fragment: "")
        #expect(empty.jumpTarget == "three.xhtml")
    }

    // MARK: position.json

    @Test("position.json round-trips, omitting an unknown CFI")
    func positionRoundTrips() throws {
        let raw = """
        {
          "chapter_key" : "002",
          "epub_cfi" : "epubcfi(/6/6!/4/2/1:0)",
          "percent" : 42.5,
          "updated_at" : "2026-09-02T10:00:00Z"
        }
        """
        // Keys happen to be alphabetical already, so the encoder reproduces
        // the file the Rust core wrote byte for byte.
        let position = try MarginsJSON.decode(ReadingPosition.self, from: Data(raw.utf8))
        #expect(position.chapterKey == "002")
        #expect(position.percent == 42.5)
        #expect(position.epubCfi == "epubcfi(/6/6!/4/2/1:0)")
        #expect(String(decoding: try MarginsJSON.encode(position), as: UTF8.self) == raw)

        let bare = ReadingPosition(chapterKey: "001", percent: 0)
        let encoded = String(decoding: try MarginsJSON.encode(bare), as: UTF8.self)
        #expect(!encoded.contains("epub_cfi"))
        #expect(!encoded.contains("updated_at"))
    }

    // MARK: notes/_index.json

    @Test("an index written before marks existed reads mark_count as 0")
    func notesIndexDefaultsMarkCount() throws {
        let raw = """
        {
          "chapters": [
            {
              "chapter_key": "001",
              "file": "chapters/001-introduction.md",
              "chapter_index": 0,
              "chapter_title": "Introduction",
              "word_count": 98,
              "updated_at": "2026-08-29T12:30:00Z"
            }
          ]
        }
        """
        let index = try MarginsJSON.decode(NotesIndex.self, from: Data(raw.utf8))
        let entry = try #require(index.chapters.first)
        #expect(entry.markCount == 0)
        #expect(entry.file == "chapters/001-introduction.md")
        #expect(entry.updatedAt == RFC3339.date(from: "2026-08-29T12:30:00Z"))
    }

    @Test("notes index entries encode every key, null timestamp included")
    func notesIndexEncodesEveryKey() throws {
        let index = NotesIndex(chapters: [
            NotesIndexEntry(
                chapterKey: "001", file: "chapters/001-introduction.md",
                chapterIndex: 0, chapterTitle: "Introduction", wordCount: 98
            )
        ])
        let encoded = String(decoding: try MarginsJSON.encode(index), as: UTF8.self)
        #expect(Self.keyNames(encoded) == [
            "chapters", "chapter_key", "file", "chapter_index", "chapter_title",
            "word_count", "mark_count", "updated_at",
        ].sorted())
        #expect(encoded.contains("\"updated_at\" : null"))
    }

    @Test("the app-facing entry drops the note's file name")
    func appFacingEntryDropsTheFile() {
        let stored = NotesIndexEntry(
            chapterKey: "004", file: "chapters/004-the-market.md",
            chapterIndex: 3, chapterTitle: "The Market", wordCount: 210, markCount: 4
        )
        let exposed = NoteIndexEntry(stored)
        #expect(exposed.id == "004")
        #expect(exposed.chapterTitle == "The Market")
        #expect(exposed.markCount == 4)
    }

    // MARK: index.json

    @Test("the library catalog round-trips with relative cover names")
    func libraryIndexRoundTrips() throws {
        let raw = """
        {
          "books" : [
            {
              "added_at" : "2026-09-02T10:00:00Z",
              "author" : "Fyodor Dostoevsky",
              "chapter_count" : 42,
              "cover" : "cover.jpg",
              "id" : "a1b2c3d4e5f6a1b2c3d4e5f6",
              "notes_count" : 3,
              "progress_percent" : 12.5,
              "title" : "The Brothers Karamazov"
            }
          ]
        }
        """
        let index = try MarginsJSON.decode(LibraryIndex.self, from: Data(raw.utf8))
        let book = try #require(index.books.first)
        #expect(book.id == book.id)
        #expect(book.cover == "cover.jpg")
        #expect(book.chapterCount == 42)
        #expect(book.progressPercent == 12.5)
        #expect(String(decoding: try MarginsJSON.encode(index), as: UTF8.self) == raw)
    }

    // MARK: Marks and frontmatter

    @Test("a page-anchored mark keeps its empty CFI and missing percent")
    func markCarriesOptionalAnchors() throws {
        let at = try #require(RFC3339.date(from: "2026-09-05T14:07:31Z"))
        let mark = Mark(id: "b01j8qk9xn", at: at, quote: "a highlight", body: "")
        #expect(mark.id == "b01j8qk9xn")
        #expect(mark.cfi == nil)
        #expect(mark.percent == nil)

        let decoded = try MarginsJSON.decode(Mark.self, from: try MarginsJSON.encode(mark))
        #expect(decoded == mark)
    }

    @Test("note frontmatter keys and order match the file format")
    func frontmatterKeysMatchTheFileFormat() throws {
        let frontmatter = NoteFrontmatter(
            bookId: "a1b2c3d4e5f6",
            chapterKey: "001",
            chapterIndex: 0,
            chapterTitle: "Introduction",
            chapterHref: "OEBPS/chapter01.xhtml",
            kind: "summary",
            wordCount: 98,
            createdAt: RFC3339.date(from: "2026-08-29T12:00:00Z"),
            updatedAt: RFC3339.date(from: "2026-08-29T12:30:00Z")
        )
        let encoded = String(decoding: try MarginsJSON.encode(frontmatter), as: UTF8.self)
        // `epub_cfi` is skipped when absent, as serde skipped it.
        #expect(Self.keyNames(encoded) == [
            "book_id", "chapter_key", "chapter_index", "chapter_title",
            "chapter_href", "kind", "word_count", "created_at", "updated_at",
        ].sorted())

        let decoded = try MarginsJSON.decode(NoteFrontmatter.self, from: Data(encoded.utf8))
        #expect(decoded == frontmatter)
    }

    @Test("frontmatter written before timestamps existed still parses")
    func frontmatterToleratesMissingTimestamps() throws {
        let raw = """
        {
          "book_id": "a1b2c3",
          "chapter_key": "001",
          "chapter_index": 0,
          "chapter_title": "Introduction",
          "chapter_href": "OEBPS/chapter01.xhtml",
          "epub_cfi": null,
          "kind": "summary",
          "word_count": 12
        }
        """
        let frontmatter = try MarginsJSON.decode(NoteFrontmatter.self, from: Data(raw.utf8))
        #expect(frontmatter.epubCfi == nil)
        #expect(frontmatter.createdAt == nil)
        #expect(frontmatter.updatedAt == nil)
    }

    // MARK: Search and export

    @Test("search hit kinds keep their kebab-case wire names")
    func searchHitKindsAreKebabCase() {
        #expect(SearchHitKind.noteContent.rawValue == "note-content")
        #expect(SearchHitKind.chapterTitle.rawValue == "chapter-title")
        #expect(SearchHitKind.bookTarget.rawValue == "book-target")
    }

    @Test("a search hit identifies by book and chapter")
    func searchHitIdentity() {
        let hit = NoteSearchHit(
            bookId: "book", bookTitle: "Book", bookAuthor: "Author",
            chapterKey: "003", chapterIndex: 2, chapterTitle: "Three",
            snippet: "a snippet", wordCount: 2, kind: .noteContent, score: 1.5,
            snippetRanges: [MatchRange(start: 2, end: 9)]
        )
        #expect(hit.id == "book/003")
        #expect(hit.snippetRanges == [MatchRange(start: 2, end: 9)])
        #expect(hit.titleRanges.isEmpty)
    }

    @Test("export defaults match the Rust Default impl")
    func exportDefaults() {
        let options = ExportOptions.default
        #expect(options.includeToc)
        #expect(options.includeStats)
        #expect(!options.includeEmptyChapters)
        #expect(options.demoteHeadings)
        #expect(ExportOptions() == options)
    }

    @Test("compiled chapters identify by chapter key")
    func compiledChapterIdentity() {
        let chapter = CompiledChapter(
            chapterKey: "007", chapterIndex: 6, chapterTitle: "Seven",
            body: "notes", wordCount: 1
        )
        #expect(chapter.id == "007")
        #expect(chapter.marks.isEmpty)
    }

    // MARK: Errors

    @Test("a core error reads as its bare message")
    func errorsReadAsTheirMessage() {
        let error = CoreError.library("book not found: abc")
        #expect(error.message == "book not found: abc")
        #expect(error.localizedDescription == "book not found: abc")
        #expect(CoreError.io("io error: no such file").message == "io error: no such file")
    }

    // MARK: Fixtures

    /// A `meta.json` in exactly the shape `serde_json::to_string_pretty`
    /// writes it, down to the key order.
    private static let metaJSON = """
    {
      "id" : "a1b2c3d4e5f6a1b2c3d4e5f6",
      "title" : "The Brothers Karamazov",
      "author" : "Fyodor Dostoevsky",
      "language" : "en",
      "added_at" : "2026-09-02T10:00:00Z",
      "source_filename" : "karamazov.epub",
      "chapters" : [
        {
          "key" : "001",
          "index" : 0,
          "title" : "Preface",
          "href" : "OEBPS/28054-h-0.htm.html"
        },
        {
          "key" : "005",
          "index" : 4,
          "title" : "Chapter II. He Gets Rid Of His Eldest Son",
          "href" : "OEBPS/28054-h-3.htm.html",
          "fragment" : "pgepubid00008"
        }
      ],
      "cover" : "cover.jpg",
      "chapters_version" : 1
    }
    """

    /// Every object key in pretty-printed JSON, sorted. Nesting makes the
    /// order the file happens to carry uninteresting; what these tests pin
    /// is which key names appear at all.
    private static func keyNames(_ json: String) -> [String] {
        let names = json.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") else {
                return nil
            }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return names.sorted()
    }
}
