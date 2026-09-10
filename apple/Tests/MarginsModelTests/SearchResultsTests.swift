import Foundation
import Testing
import MarginsCore
import MarginsModel

@Suite("SearchResults")
struct SearchResultsTests {
    private func makeHit(
        bookId: String,
        kind: SearchHitKind,
        chapterKey: String = "001",
        chapterTitle: String = "Chapter"
    ) -> NoteSearchHit {
        NoteSearchHit(
            bookId: bookId,
            bookTitle: "Book",
            bookAuthor: "Author",
            chapterKey: chapterKey,
            chapterIndex: 0,
            chapterTitle: chapterTitle,
            snippet: "snippet",
            wordCount: 1,
            kind: kind,
            score: 1,
            snippetRanges: [],
            titleRanges: []
        )
    }

    @Test("sections partition by kind: navigation targets above notes")
    func sectionsPartitionByKind() {
        let hits = [
            makeHit(bookId: "a", kind: .noteContent),
            makeHit(bookId: "b", kind: .bookTarget, chapterKey: ""),
            makeHit(bookId: "c", kind: .chapterTitle),
        ]
        let sections = SearchResultsOrganizer.sections(for: hits)
        #expect(sections.count == 2)
        #expect(sections[0].title == "Chapters")
        #expect(sections[0].hits.map(\.bookId) == ["b", "c"])
        #expect(sections[1].title == "Notes")
        #expect(sections[1].hits.map(\.bookId) == ["a"])

        // Navigation order flattens sections back, preserving relevance.
        let flat = SearchResultsOrganizer.flatOrder(for: hits)
        #expect(flat.map(\.bookId) == ["b", "c", "a"])

        #expect(SearchResultsOrganizer.sections(for: []).isEmpty)
    }

    @Test("highlighter applies exactly the provided UTF-16 ranges")
    func highlighterAppliesExactRanges() {
        // "café culture and more café": café occupies 0–4 and 22–26 in
        // UTF-16 (é is one unit). Two terms → two ranges in one row.
        let text = "café culture and more café"
        let ranges = [MatchRange(start: 0, end: 4), MatchRange(start: 22, end: 26)]

        let attributed = SearchHighlighter.attributed(
            text,
            ranges: ranges,
            highlight: SearchHighlighter.highlightIntent
        )

        var spans: [(text: String, emphasized: Bool)] = []
        for run in attributed.runs {
            let runText = String(attributed[run.range].characters)
            let emphasized = run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
            spans.append((runText, emphasized))
        }
        #expect(spans.count == 3)
        #expect(spans[0] == ("café", true))
        #expect(spans[1] == (" culture and more ", false))
        #expect(spans[2] == ("café", true))
    }

    @Test("highlighter handles empty and overlapping ranges defensively")
    func highlighterDefensiveRanges() {
        let attributed = SearchHighlighter.attributed(
            "plain text",
            ranges: [],
            highlight: SearchHighlighter.highlightIntent
        )
        #expect(String(attributed.characters) == "plain text")
        #expect(attributed.runs.count == 1)

        // An overlap with the cursor is skipped, not double-applied.
        let overlapped = SearchHighlighter.attributed(
            "abcdef",
            ranges: [MatchRange(start: 0, end: 3), MatchRange(start: 2, end: 5)],
            highlight: SearchHighlighter.highlightIntent
        )
        var emphasized = ""
        for run in overlapped.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            emphasized += String(overlapped[run.range].characters)
        }
        #expect(emphasized == "abc")
    }
}

@Suite("SearchSelection")
@MainActor
struct SearchSelectionTests {
    private func makeHit(bookId: String, kind: SearchHitKind) -> NoteSearchHit {
        NoteSearchHit(
            bookId: bookId,
            bookTitle: "Book",
            bookAuthor: "Author",
            chapterKey: kind == .bookTarget ? "" : "001",
            chapterIndex: 0,
            chapterTitle: kind == .bookTarget ? "" : "Chapter",
            snippet: "snippet",
            wordCount: 1,
            kind: kind,
            score: 1,
            snippetRanges: [],
            titleRanges: []
        )
    }

    @Test("selection math wraps at both ends and clamps to empty lists")
    func selectionMathWraps() {
        #expect(SearchController.movedSelection(current: nil, count: 3, delta: 1) == 0)
        #expect(SearchController.movedSelection(current: nil, count: 3, delta: -1) == 2)
        #expect(SearchController.movedSelection(current: 0, count: 3, delta: -1) == 2)
        #expect(SearchController.movedSelection(current: 2, count: 3, delta: 1) == 0)
        #expect(SearchController.movedSelection(current: 1, count: 3, delta: 1) == 2)
        #expect(SearchController.movedSelection(current: nil, count: 0, delta: 1) == nil)
    }

    @Test("selection navigates the sectioned display order")
    func selectionFollowsFlatOrder() async throws {
        let controller = SearchController(defaults: makeDefaults())
        // Mixed kinds: display order is [chapterTitle, bookTarget, noteContent].
        let hits = [
            makeHit(bookId: "note", kind: .noteContent),
            makeHit(bookId: "book", kind: .bookTarget),
            makeHit(bookId: "title", kind: .chapterTitle),
        ]
        controller.setExecutor { _ in hits }
        controller.debounceSleep = { _ in }

        controller.setQuery("query")
        await waitForResults(controller, count: 3)
        // Within the Chapters section, the backend's relevance order stands.
        #expect(controller.orderedResults.map(\.bookId) == ["book", "title", "note"])

        controller.moveSelection(1)
        #expect(controller.selectedHit?.bookId == "book")
        controller.moveSelection(1)
        #expect(controller.selectedHit?.bookId == "title")
        controller.moveSelection(1)
        #expect(controller.selectedHit?.bookId == "note")
        controller.moveSelection(1)
        #expect(controller.selectedHit?.bookId == "book", "selection wraps to the first row")
        controller.moveSelection(-1)
        #expect(controller.selectedHit?.bookId == "note", "selection wraps past the top")
    }

    /// Event-driven wait for the debounced search to land; a fixed sleep
    /// raced the debounce on loaded CI runners.
    private func waitForResults(_ controller: SearchController, count: Int) async {
        for _ in 0..<1_000 {
            if controller.orderedResults.count == count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(count) ordered results")
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SearchSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
