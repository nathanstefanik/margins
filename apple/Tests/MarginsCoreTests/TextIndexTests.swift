import Foundation
import Testing

@testable import MarginsCore

/// The Karamazov-fixture group: one real import+index shared across the
/// suite (the build takes real seconds, so it is paid once). The removal
/// test builds its own store so it cannot corrupt the shared one.
@Suite("Text index (Karamazov)", .serialized)
struct TextIndexTests {
    struct Indexed: Sendable {
        var dataDir: String
        var store: CoreStore
        var bookId: String
    }

    /// Built once per suite — the serialized trait makes the lazy init
    /// single-threaded.
    private final class SharedIndex: @unchecked Sendable {
        var value: Indexed?
    }

    private static let shared = SharedIndex()

    /// The suite-wide indexed book; sibling suites (the scale probe)
    /// reuse it.
    static func sharedHarness() async throws -> Indexed {
        if let cached = Self.shared.value { return cached }
        let created = try await Self.makeIndexed()
        Self.shared.value = created
        return created
    }

    private static func makeIndexed() async throws -> Indexed {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-textindex-\(UUID().uuidString)", isDirectory: true)
        let dataDir = root.appendingPathComponent("data").path
        let store = try CoreStore(dataDir: dataDir)
        try await store.setLibraryRoot(
            path: root.appendingPathComponent("library").path)
        let epub = try Fixtures.url("dostoyevsky_the_karamazov_brothers.epub").path
        let meta = try await store.importEpub(atPath: epub)
        let clock = ContinuousClock()
        let start = clock.now
        let built = try await store.indexBookText(bookId: meta.id, epubPath: nil)
        let elapsed = start.duration(to: clock.now)
        print("[TextIndex] Karamazov build: \(elapsed) (built=\(built))")
        return Indexed(dataDir: dataDir, store: store, bookId: meta.id)
    }

    private func indexed() async throws -> Indexed {
        try await Self.sharedHarness()
    }

    private func search(_ store: CoreStore, _ query: String) async throws
        -> [TextSearchHit]
    {
        let clock = ContinuousClock()
        let start = clock.now
        let hits = try await store.searchBookText(query: query)
        print("[TextIndex] query \"\(query)\": \(hits.count) hits in \(start.duration(to: clock.now))")
        return hits
    }

    // MARK: Relevance

    @Test("“lie to yourself” ranks the phrase first")
    func lieToYourself() async throws {
        let indexed = try await indexed()
        let hits = try await search(indexed.store, "lie to yourself")
        let hit = try #require(hits.first)
        #expect(hit.passage.contains("lie to yourself"))
    }

    @Test("a typo-laden query still finds the passage in the top three")
    func typoQuery() async throws {
        let indexed = try await indexed()
        let hits = try await search(indexed.store, "above all dont lye to yourslf")
        let top = hits.prefix(3)
        #expect(top.contains { $0.passage.contains("lie to yourself") })
    }

    @Test("“sticky little leaves” — phrase, prefix, and trailing space")
    func stickyLittleLeaves() async throws {
        let indexed = try await indexed()

        // The in-order phrase bonus (×2.0) puts the verbatim phrase first.
        let phrase = try await search(indexed.store, "sticky little leaves")
        #expect(phrase.first?.passage.contains("sticky little leaves") == true)

        // A trailing partial word prefix-expands.
        let prefix = try await search(indexed.store, "sticky little lea")
        #expect(prefix.first?.passage.contains("sticky little leav") == true)

        // Trailing space means "lea" is complete — no prefix expansion,
        // and at three letters it is too short for typo fallback: with
        // soft AND every returned passage must cover ≥2 of the 3 terms.
        let exact = try await search(indexed.store, "sticky little lea ")
        #expect(
            exact.allSatisfy { hit in
                let stems = Set(TextAnalyzer.tokens(hit.passage).map(\.stem))
                return ["sticki", "littl", "lea"].filter(stems.contains).count >= 2
            })
        // And a lone "lea " proves prefix expansion stayed off: a hit's
        // passage can only contain a token stemming to "lea" itself.
        let lone = try await search(indexed.store, "lea ")
        #expect(
            lone.allSatisfy { hit in
                TextAnalyzer.tokens(hit.passage).contains { $0.stem == "lea" }
            })
    }

    @Test("diacritic-insensitive terms match folded text")
    func cafeRestaurant() async throws {
        let indexed = try await indexed()
        let hits = try await search(indexed.store, "cafe restaurant")
        #expect(hits.contains { $0.passage.contains("café restaurant") })
    }

    @Test("stemmed queries hit inflected forms")
    func deceiving() async throws {
        let indexed = try await indexed()
        let hits = try await search(indexed.store, "deceiving")
        #expect(
            hits.contains {
                $0.passage.range(of: "deceiv", options: .caseInsensitive) != nil
            })
    }

    @Test("snippetRanges index correctly into the snippet")
    func snippetRanges() async throws {
        let indexed = try await indexed()
        let hits = try await search(indexed.store, "lie to yourself")
        let hit = try #require(hits.first)
        #expect(!hit.snippetRanges.isEmpty)
        let utf16 = Array(hit.snippet.utf16)
        let queryStems = TextAnalyzer.tokens("lie to yourself").map(\.stem)
        for range in hit.snippetRanges {
            #expect(range.start >= 0 && range.end <= utf16.count && range.start < range.end)
            let word = String(String(decoding: utf16[range.start..<range.end], as: UTF16.self))
            // Each highlighted word analyzes to one of the query terms'
            // stems (exact or prefix-expanded).
            let stems = TextAnalyzer.tokens(word).map(\.stem)
            #expect(
                stems.contains { stem in
                    queryStems.contains { $0 == stem || stem.hasPrefix($0) }
                },
                "\(word) is not a match for the query")
        }
    }

    // MARK: Layout

    @Test("index files exist on disk and the directory is excluded from backup")
    func layoutAndExclusion() async throws {
        let indexed = try await indexed()
        let dir = indexed.dataDir.appendingPathComponent("text-index")
        let bookDir = dir.appendingPathComponent("books/\(indexed.bookId)")

        #expect(try Files.read(dir.appendingPathComponent("FORMAT")).trimmed == "1")
        #expect(Files.isFile(dir.appendingPathComponent("stats.json")))
        #expect(Files.isFile(dir.appendingPathComponent("vocab.tsv")))
        #expect(Files.isFile(bookDir.appendingPathComponent("manifest.json")))
        #expect(Files.isFile(bookDir.appendingPathComponent("passages.jsonl")))
        #expect(Files.isFile(bookDir.appendingPathComponent("terms.tsv")))

        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("indexing an already-current book is a no-op")
    func indexTwiceFalse() async throws {
        let indexed = try await indexed()
        #expect(try await indexed.store.indexBookText(bookId: indexed.bookId, epubPath: nil) == false)
    }

    // MARK: Removal (own store — mutates)

    @Test("removing a book deletes its index and subtracts its vocabulary")
    func removeBookCleans() async throws {
        // A separate store: this test deletes the book outright.
        let built = try await Self.makeIndexed()
        let bookDir = built.dataDir
            .appendingPathComponent("text-index/books/\(built.bookId)")
        let vocabPath = built.dataDir.appendingPathComponent("text-index/vocab.tsv")

        let status = try await built.store.textIndexStatus()
        #expect(status.indexedBookIds == [built.bookId])
        #expect(status.pendingBookIds.isEmpty)

        try await built.store.removeBook(id: built.bookId)

        #expect(!Files.exists(bookDir))
        // "karamazov" is a stem no other indexed book contributes.
        let vocab = (try? Files.read(vocabPath)) ?? ""
        #expect(
            !vocab.split(separator: "\n").contains {
                $0.split(separator: "\t").first == "karamazov"
            })
        #expect(try await built.store.searchBookText(query: "karamazov").isEmpty)
        #expect(try await built.store.textIndexStatus().indexedBookIds.isEmpty)
    }
}
