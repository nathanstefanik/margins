import Foundation
import Testing

@testable import MarginsCore

/// Tiny synthetic books via `EpubFixtureBuilder` — controlled passage
/// text for soft-AND/proximity/IDF semantics plus index lifecycle cases
/// (FORMAT wipe, stats recovery, removal, concurrent builds).
@Suite("Text index (synthetic)", .serialized)
struct TextIndexSyntheticTests {
    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-textidx-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A store with the epub built from `chapters` imported; indexes it
    /// too when `index` is set.
    private func store(
        at root: URL, chapters: [EpubFixtureBuilder.ChapterSpec],
        named name: String = "book.epub", index: Bool = true
    ) async throws -> (store: CoreStore, bookId: String) {
        let store = try CoreStore(dataDir: root.appendingPathComponent("data").path)
        try await store.setLibraryRoot(path: root.appendingPathComponent("library").path)
        let epub = try EpubFixtureBuilder.epub(
            in: root, named: name, bookTitle: "Synthetic", chapters: chapters)
        let meta = try await store.importEpub(atPath: epub)
        if index {
            _ = try await store.indexBookText(bookId: meta.id, epubPath: nil)
        }
        return (store, meta.id)
    }

    /// A chapter whose XHTML body is used verbatim (`markedUpBody` —
    /// `body` would be escaped inside a single `<p>`), with an `<h1>`
    /// for the chapter title.
    private func chapter(_ name: String, _ body: String) -> EpubFixtureBuilder.ChapterSpec {
        EpubFixtureBuilder.ChapterSpec(
            filename: "\(name).xhtml",
            markedUpBody: "<h1>\(name)</h1>\(body)")
    }

    private func search(_ store: CoreStore, _ query: String) async throws
        -> [TextSearchHit]
    {
        try await store.searchBookText(query: query)
    }

    // MARK: Scoring semantics

    @Test("soft AND: 3-of-4 terms hits, 2-of-4 does not, 2-term needs both")
    func softAnd() async throws {
        let root = tempRoot("softand")
        let (store, _) = try await store(
            at: root,
            chapters: [
                chapter(
                    "a",
                    """
                    <p>alpha bravo charlie filler words fill this line out.</p>
                    <p>alpha bravo only two of the four wanted terms here.</p>
                    <p>alpha delta both of the two wanted terms appear.</p>
                    """)
            ])

        let four = try await search(store, "alpha bravo charlie delta")
        #expect(four.count == 1)
        #expect(four[0].passage.contains("filler words"))

        let two = try await search(store, "alpha delta")
        #expect(two.count == 1)
        #expect(two[0].passage.contains("wanted terms appear"))
    }

    @Test("adjacent terms outrank a distant window at the same tf")
    func proximity() async throws {
        let root = tempRoot("prox")
        let filler = (1...30).map { "filler\($0)" }.joined(separator: " ")
        let (store, _) = try await store(
            at: root,
            chapters: [
                chapter(
                    "a",
                    "<p>alpha \(filler) beta.</p><p>alpha beta adjacent.</p>")
            ])

        let hits = try await search(store, "alpha beta")
        #expect(hits.count == 2)
        #expect(hits[0].passage.contains("adjacent"))
        #expect(hits[0].score > hits[1].score)
    }

    @Test("a rare term outweighs a common one (IDF)")
    func idf() async throws {
        let root = tempRoot("idf")
        // "common" appears in every passage; "rarebird" in exactly one.
        let commonParagraphs = (1...8).map {
            "<p>common word in passage \($0) with filler.</p>"
        }.joined()
        let (store, _) = try await store(
            at: root,
            chapters: [
                chapter("a", "<p>rarebird appears once.</p>\(commonParagraphs)")
            ])

        let rare = try await search(store, "rarebird")
        let common = try await search(store, "common")
        #expect(rare.first?.score ?? 0 > (common.first?.score ?? 0) * 2)
    }

    // MARK: Lifecycle

    @Test("a FORMAT mismatch wipes the index and the next build recreates it")
    func formatMismatch() async throws {
        let root = tempRoot("format")
        let (store, bookId) = try await store(
            at: root, chapters: [chapter("a", "<p>needle in the haystack.</p>")])
        let indexDir = root.appendingPathComponent("data/text-index").path
        #expect(try await !search(store, "needle").isEmpty)

        // Corrupt the version marker; a fresh TextIndex (new store)
        // wipes and starts clean on its first use.
        try Files.write("99\n", to: indexDir.appendingPathComponent("FORMAT"))
        let store2 = try CoreStore(dataDir: root.appendingPathComponent("data").path)
        try await store2.setLibraryRoot(path: root.appendingPathComponent("library").path)
        let wiped = try await store2.searchBookText(query: "needle")
        #expect(wiped.isEmpty)
        #expect(try await store2.indexBookText(bookId: bookId, epubPath: nil))
        #expect(try Files.read(indexDir.appendingPathComponent("FORMAT")).trimmed == "1")
        let rebuilt = try await store2.searchBookText(query: "needle")
        #expect(!rebuilt.isEmpty)
    }

    @Test("a lost stats.json rebuilds vocabulary and stats identically")
    func crashRecovery() async throws {
        let root = tempRoot("crash")
        let (store, _) = try await store(
            at: root, chapters: [chapter("a", "<p>rebuild me later.</p>")])
        let indexDir = root.appendingPathComponent("data/text-index").path
        let statsPath = indexDir.appendingPathComponent("stats.json")
        let vocab = try Files.read(indexDir.appendingPathComponent("vocab.tsv"))

        try Files.remove(statsPath)
        let store2 = try CoreStore(dataDir: root.appendingPathComponent("data").path)
        try await store2.setLibraryRoot(path: root.appendingPathComponent("library").path)

        let hits = try await store2.searchBookText(query: "rebuild")
        #expect(hits.first?.passage.contains("rebuild me later") == true)
        #expect(Files.isFile(statsPath))
        #expect(try Files.read(indexDir.appendingPathComponent("vocab.tsv")) == vocab)
        #expect(try await store.indexBookText(bookId: hits[0].bookId, epubPath: nil) == false)
    }

    @Test("a book no longer in the library is excluded from results")
    func removedBookExcluded() async throws {
        let root = tempRoot("removed")
        let (store, bookA) = try await store(
            at: root, chapters: [chapter("a", "<p>sharedneedle in book a.</p>")],
            named: "a.epub")
        // A different body → a different content-hash book id.
        let epubB = try EpubFixtureBuilder.epub(
            in: root, named: "b.epub", bookTitle: "Synthetic B",
            chapters: [chapter("a", "<p>sharedneedle in book b.</p>")])
        let metaB = try await store.importEpub(atPath: epubB)
        _ = try await store.indexBookText(bookId: metaB.id, epubPath: nil)
        #expect(try await search(store, "sharedneedle").count == 2)

        try await store.removeBook(id: bookA)
        let hits = try await search(store, "sharedneedle")
        #expect(hits.count == 1)
        #expect(hits[0].bookId == metaB.id)
    }

    @Test("concurrent indexBookText for one book yields exactly one build")
    func concurrentBuild() async throws {
        let root = tempRoot("concurrent")
        let (store, bookId) = try await store(
            at: root, chapters: [chapter("a", "<p>build me once.</p>")], index: false)
        async let first = store.indexBookText(bookId: bookId, epubPath: nil)
        async let second = store.indexBookText(bookId: bookId, epubPath: nil)
        let a = try await first
        let b = try await second
        #expect(a != b)
    }

    @Test("searchBookText and textIndexStatus never rewrite the library index")
    func searchDoesNotRewriteLibraryIndex() async throws {
        let root = tempRoot("norewrite")
        let (store, _) = try await store(
            at: root, chapters: [chapter("a", "<p>needle in the haystack.</p>")])
        // Prime the synced index.json, then hold its timestamp.
        _ = try await store.listBooks()
        let indexPath = root.appendingPathComponent("library/index.json").path
        let before = try FileManager.default.attributesOfItem(atPath: indexPath)[
            .modificationDate] as? Date
        #expect(before != nil)

        for _ in 0..<3 {
            _ = try await store.searchBookText(query: "needle")
            _ = try await store.textIndexStatus()
        }
        let after = try FileManager.default.attributesOfItem(atPath: indexPath)[
            .modificationDate] as? Date
        #expect(after == before)
    }

    // MARK: Scale probe

    /// Reuses the Karamazov suite's index under twenty book ids — the
    /// point is postings ×20, not build time — and times every fixture
    /// query against all twenty.
    @Test("twenty-book scale probe")
    func scaleProbe() async throws {
        let indexed = try await TextIndexTests.sharedHarness()
        let indexDir = indexed.dataDir.appendingPathComponent("text-index")
        let bookDir = indexDir.appendingPathComponent("books/\(indexed.bookId)")

        var ids = [indexed.bookId]
        for i in 0..<19 {
            let clone = indexDir.appendingPathComponent("books/\(indexed.bookId)-s\(i)")
            try FileManager.default.copyItem(atPath: bookDir, toPath: clone)
            ids.append("\(indexed.bookId)-s\(i)")
        }

        // A fresh TextIndex reconciles stats.books vs the 20 dirs.
        let probe = TextIndex(directory: indexDir)
        try probe.ensure()
        #expect(probe.indexedBookIds().count == 20)
        let bookIds = Set(ids)

        let clock = ContinuousClock()
        var start = clock.now
        _ = try probe.search(query: "lie to yourself", bookIds: bookIds, limit: 50)
        print("[TextIndex] 20-book warm-up (line-index build): \(start.duration(to: clock.now))")

        for query in [
            "lie to yourself", "above all dont lye to yourslf",
            "sticky little leaves", "sticky little lea",
            "cafe restaurant", "deceiving",
        ] {
            start = clock.now
            let hits = try probe.search(query: query, bookIds: bookIds, limit: 50)
            print(
                "[TextIndex] 20-book \"\(query)\": \(hits.count) hits in \(start.duration(to: clock.now))"
            )
        }
    }
}
