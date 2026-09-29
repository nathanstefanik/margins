import Foundation
import Testing

@testable import MarginsModel
import MarginsCore

private func capturedHit(
    _ kind: SearchHitKind, id: String = "b",
    markId: String? = nil, notebookId: String? = nil
) -> NoteSearchHit {
    NoteSearchHit(
        bookId: id, bookTitle: "T", bookAuthor: "A",
        chapterKey: kind == .notebook ? "" : "c",
        chapterIndex: 0, chapterTitle: "Ch",
        snippet: "snippet", wordCount: 3, kind: kind, score: 1,
        markId: markId, notebookId: notebookId)
}

private func textHit(_ bookId: String = "b") -> TextSearchHit {
    TextSearchHit(
        bookId: bookId, bookTitle: "T", bookAuthor: "A",
        chapterKey: "c", chapterIndex: 0, chapterTitle: "Ch",
        passage: "a whole passage", passageIndex: 0,
        snippet: "snippet", snippetRanges: [], score: 1)
}

/// A sendable box so @Sendable executors can signal the test.
private final class SendableFlag: @unchecked Sendable {
    var value = false
}

@Suite("Library search")
@MainActor
struct LibrarySearchTests {

    @Test("sections follow the fixed order and omit empty groups")
    func sectionsOrder() {
        let captured = [
            capturedHit(.chapterTitle), capturedHit(.mark, markId: "m1"), capturedHit(.noteContent),
            capturedHit(.notebook, notebookId: "n1"), capturedHit(.bookTarget),
        ]
        let sections = LibrarySearch.sections(captured: captured, fullText: [textHit()])
        #expect(
            sections.map(\.title)
                == ["Passages", "In Your Books", "Notebooks", "Notes", "Chapters & Books"])
        #expect(sections[0].items.count == 1)  // the mark
        #expect(sections[4].items.count == 2)  // chapter + book

        // No full text → its section drops out entirely.
        let without = LibrarySearch.sections(captured: captured, fullText: [])
        #expect(without.map(\.title) == ["Passages", "Notebooks", "Notes", "Chapters & Books"])
        #expect(LibrarySearch.sections(captured: [], fullText: []).isEmpty)
    }

    @Test("passageSource maps marks and text hits, nothing else")
    func passageSource() {
        let mark = LibrarySearchItem.captured(capturedHit(.mark, markId: "m7"))
        #expect(
            LibrarySearch.passageSource(for: mark)
                == .mark(bookId: "b", chapterKey: "c", markId: "m7"))

        let text = LibrarySearchItem.text(textHit("b2"))
        #expect(
            LibrarySearch.passageSource(for: text)
                == .selection(
                    bookId: "b2", chapterKey: "c", cfi: nil, percent: nil,
                    quote: "a whole passage"))

        #expect(LibrarySearch.passageSource(for: .captured(capturedHit(.noteContent))) == nil)
        // A mark hit without its mark id can't resolve either.
        #expect(LibrarySearch.passageSource(for: .captured(capturedHit(.mark))) == nil)
    }

    @Test("latest-wins: a stale executor's result never lands")
    @MainActor
    func latestWins() async throws {
        let search = LibrarySearch()
        search.debounceSleep = { _ in }
        // The first query resolves slowly; the second answers at once.
        search.capturedExecutor = { query in
            if query == "first" { try await Task.sleep(for: .milliseconds(200)) }
            return [capturedHit(.noteContent)]
        }
        search.fullTextExecutor = { query in
            if query == "first" { try await Task.sleep(for: .milliseconds(200)) }
            return [textHit()]
        }

        search.setQuery("first")
        search.setQuery("second")
        try await Task.sleep(for: .milliseconds(400))

        // Both queries ran through, but only the latest is applied.
        #expect(search.captured.count == 1)
        #expect(search.fullText.count == 1)
        #expect(search.isSearching == false)
    }

    @Test("an empty query clears everything without running")
    @MainActor
    func emptyClears() async {
        let search = LibrarySearch()
        search.debounceSleep = { _ in }
        let ran = SendableFlag()
        search.capturedExecutor = { _ in ran.value = true; return [] }
        search.setQuery("x")
        search.setQuery("   ")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(ran.value == false)
        #expect(search.captured.isEmpty && search.fullText.isEmpty)
        #expect(search.isSearching == false)
    }
}
