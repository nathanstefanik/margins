import Foundation
import Testing
import MarginsCore
import MarginsModel

@Suite("SearchController")
@MainActor
struct SearchControllerTests {
    /// Records executions; can simulate slow backends and per-query results.
    private actor SpyStore: SearchStore {
        private var calls: [String] = []
        private var delayMs: UInt64
        private var canned: [String: [NoteSearchHit]]

        init(delayMs: UInt64 = 0) {
            self.delayMs = delayMs
            self.canned = [:]
        }

        func searchNotes(query: String) async throws -> [NoteSearchHit] {
            calls.append(query)
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            return canned[query] ?? []
        }

        func setCanned(_ hits: [NoteSearchHit], for query: String) {
            canned[query] = hits
        }

        func recordedCalls() -> [String] {
            calls
        }
    }

    private func makeHit(bookId: String, snippet: String) -> NoteSearchHit {
        NoteSearchHit(
            bookId: bookId,
            bookTitle: "Book \(bookId)",
            bookAuthor: "Author",
            chapterKey: "001",
            chapterIndex: 0,
            chapterTitle: "Chapter",
            snippet: snippet,
            wordCount: 3,
            kind: .noteContent,
            score: 1.5,
            snippetRanges: [MatchRange(start: 0, end: 3)],
            titleRanges: []
        )
    }

    @Test("a typing burst produces exactly one backend query, latest wins")
    func burstYieldsOneQuery() async throws {
        let spy = SpyStore()
        let controller = SearchController(defaults: makeDefaults())
        controller.setExecutor { [spy] text in
            (try? await spy.searchNotes(query: text)) ?? []
        }

        controller.setQuery("f")
        controller.setQuery("fa")
        controller.setQuery("fait")

        try await Task.sleep(for: .milliseconds(400))
        let calls = await spy.recordedCalls()
        #expect(calls == ["fait"])
        #expect(controller.isSearching == false)
    }

    @Test("stale in-flight results never overwrite newer ones")
    func staleResultsNeverOverwrite() async throws {
        let spy = SpyStore(delayMs: 120)
        let controller = SearchController(defaults: makeDefaults())
        controller.debounceInterval = 0.02
        controller.setExecutor { [spy] text in
            (try? await spy.searchNotes(query: text)) ?? []
        }
        await spy.setCanned([makeHit(bookId: "1", snippet: "hits:first")], for: "first")
        await spy.setCanned([makeHit(bookId: "2", snippet: "hits:second")], for: "second")

        controller.setQuery("first")
        // The first query is now in flight; retype before it lands.
        try await Task.sleep(for: .milliseconds(60))
        controller.setQuery("second")

        try await Task.sleep(for: .milliseconds(400))
        let calls = await spy.recordedCalls()
        #expect(calls == ["first", "second"])
        #expect(controller.results.count == 1)
        #expect(controller.results.first?.snippet == "hits:second")
        #expect(controller.isSearching == false)
    }

    @Test("results are capped and the truncation flag is surfaced")
    func resultCapIsSurfaced() async throws {
        let spy = SpyStore()
        let controller = SearchController(defaults: makeDefaults())
        controller.setExecutor { [spy] text in
            (try? await spy.searchNotes(query: text)) ?? []
        }
        let many = (0..<60).map { makeHit(bookId: "b\($0)", snippet: "hits:flood") }
        await spy.setCanned(many, for: "flood")

        controller.setQuery("flood")
        try await Task.sleep(for: .milliseconds(400))

        #expect(controller.results.count == SearchController.resultCap)
        #expect(controller.isTruncated == true)
    }

    @Test("recents dedupe case-insensitively, cap at five, and persist")
    func recentsRoundTrip() throws {
        let defaults = makeDefaults()
        let controller = SearchController(defaults: defaults)

        for query in ["alpha", "beta", "Alpha", "gamma", "delta", "epsilon", "zeta"] {
            controller.commitRecent(query)
        }
        // "Alpha" deduped "alpha" (latest casing wins); "beta" fell off the cap.
        #expect(controller.recents == ["zeta", "epsilon", "delta", "gamma", "Alpha"])

        // A fresh controller over the same suite restores the recents.
        let revived = SearchController(defaults: defaults)
        #expect(revived.recents == controller.recents)
    }

    @Test("empty and whitespace queries clear results without querying")
    func emptyQueryClears() async throws {
        let spy = SpyStore()
        let controller = SearchController(defaults: makeDefaults())
        controller.setExecutor { [spy] text in
            (try? await spy.searchNotes(query: text)) ?? []
        }
        await spy.setCanned([makeHit(bookId: "1", snippet: "hits:text")], for: "text")

        controller.setQuery("text")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.results.isEmpty)

        controller.setQuery("   ")
        #expect(controller.query == "   ")
        #expect(controller.results.isEmpty)
        #expect(controller.isSearching == false)

        try await Task.sleep(for: .milliseconds(200))
        let calls = await spy.recordedCalls()
        #expect(calls == ["text"])
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SearchControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
