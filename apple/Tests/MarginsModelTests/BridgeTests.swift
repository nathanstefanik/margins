import Foundation
import Testing
import MarginsCore

@Suite("MarginsCore bridge")
struct BridgeTests {
    @Test("dataDir is honored")
    func dataDirIsHonored() async throws {
        let dir = try makeTempDataDir()
        let store = try CoreStore(dataDir: dir)
        let resolved = try await store.dataDir()
        #expect(resolved == dir)
    }

    @Test("import through the bridge agrees with the stored metadata")
    func importAgreesWithStoredMetadata() async throws {
        let fixtures = try fixtureEpubs()
        #expect(!fixtures.isEmpty, "expected at least one fixtures/*.epub to exercise the bridge")

        for fixture in fixtures {
            let store = try CoreStore(dataDir: try makeTempDataDir())

            let imported = try await store.importEpub(atPath: fixture)
            #expect(!imported.title.isEmpty)
            #expect(!imported.author.isEmpty)
            #expect(!imported.chapters.isEmpty)

            // Reading back through a second bridge call must agree with the
            // import-time parse (same contract as the core integration test).
            let reread = try await store.getBook(id: imported.id)
            #expect(reread.title == imported.title)
            #expect(reread.author == imported.author)
            #expect(reread.chapters.count == imported.chapters.count)

            let summaries = try await store.listBooks()
            #expect(summaries.count == 1)
            #expect(summaries.first?.id == imported.id)
            #expect(summaries.first?.chapterCount == UInt32(imported.chapters.count))
        }
    }

    @Test("cover path crosses the FFI and points at an existing file")
    func coverPathCrossesTheBridge() async throws {
        // The fixture EPUB declares its cover via EPUB2 <meta name="cover">;
        // the extraction must surface it as an absolute path on both records.
        let fixtures = try fixtureEpubs()
        #expect(!fixtures.isEmpty)

        let store = try CoreStore(dataDir: try makeTempDataDir())
        let imported = try await store.importEpub(atPath: fixtures[0])

        let coverPath = try #require(imported.coverPath, "expected the fixture book to have a cover")
        #expect(FileManager.default.fileExists(atPath: coverPath))
        #expect(coverPath.hasSuffix(".png") || coverPath.hasSuffix(".jpg"))

        let reread = try await store.getBook(id: imported.id)
        #expect(reread.coverPath == coverPath)

        let summaries = try await store.listBooks()
        #expect(summaries.first?.coverPath == coverPath)
    }

    @Test("search hits cross the FFI with kind, score, and match ranges")
    func searchHitsCrossTheBridge() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let imported = try await store.importEpub(atPath: fixture)
        let chapter = try #require(imported.chapters.first)

        let body = "The xylophone motif returns in Café scenes."
        _ = try await store.saveChapterNote(
            bookId: imported.id,
            chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: body,
            kind: nil
        )

        let hits = try await store.searchNotes(query: "xylophone")
        let hit = try #require(hits.first)
        #expect(hit.kind == .noteContent)
        #expect(hit.score > 0)
        #expect(hit.snippet.contains("xylophone"))

        // Ranges are valid UTF-16 indices into the snippet and point at the
        // matched word — the UI must be able to highlight without re-matching.
        let snippet16 = Array(hit.snippet.utf16)
        #expect(!hit.snippetRanges.isEmpty)
        for range in hit.snippetRanges {
            #expect(range.start < range.end)
            #expect(range.end <= snippet16.count)
            let matched = String(
                decoding: snippet16[Int(range.start)..<Int(range.end)],
                as: UTF16.self
            )
            #expect(matched.lowercased().hasPrefix("xylophone"))
        }
    }
}
