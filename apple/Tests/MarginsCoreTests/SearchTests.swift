import Foundation
@testable import MarginsCore
import Testing

/// Translated from the legacy core's search test module. Two
/// things are under test throughout: the ranking is deterministic and
/// explainable, and the warm index never disagrees with a cold scan — notes
/// edited by an agent or an external editor have to surface on the next
/// query.
@Suite("Search")
struct SearchTests {
    private struct Harness {
        let root: URL
        let library: Library
        let bookID: String
        let chapters: [ChapterMeta]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("margins-search-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try Library(root: root.appendingPathComponent("library").path)
            let epub = try EpubFixtureBuilder.sampleEpub(in: root)
            let meta = try library.importEpub(atPath: epub)
            bookID = meta.id
            chapters = meta.chapters
        }

        func saveNote(_ chapter: ChapterMeta, _ body: String) throws {
            try Notes.saveChapterNote(
                bookDir: library.bookDir(bookID),
                chapter: chapter,
                frontmatter: NoteFrontmatter(
                    bookId: bookID,
                    chapterKey: chapter.key,
                    chapterIndex: chapter.index,
                    chapterTitle: chapter.title,
                    chapterHref: chapter.href,
                    kind: "summary",
                    wordCount: Notes.countWords(body)
                ),
                body: body
            )
            library.refreshNoteIndex(bookID: bookID)
        }
    }

    @Test("an empty or whitespace query returns nothing")
    func emptyQueryReturnsNothing() throws {
        let harness = try Harness()
        #expect(harness.library.searchNotes(query: "").isEmpty)
        #expect(harness.library.searchNotes(query: "   \t ").isEmpty)
    }

    @Test("case folding is Unicode-aware")
    func unicodeCaseFolding() throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "Café culture thrives here.")
        try harness.saveNote(harness.chapters[1], "The STRAßE was quiet.")

        let cafe = harness.library.searchNotes(query: "café")
        #expect(cafe.count == 1)
        #expect(cafe[0].snippet.contains("Café"))

        // "STRAßE" folds to "straße"; the query folds the same way.
        let strasse = harness.library.searchNotes(query: "straße")
        #expect(strasse.count == 1)
        #expect(strasse[0].snippet.contains("STRAßE"))
    }

    @Test("terms match as token prefixes, so results appear mid-word")
    func prefixMatchesMidWord() throws {
        let harness = try Harness()
        // "squar" prefixes "square" in the body; the other chapter's title
        // ("The Market") must not match this term.
        try harness.saveNote(harness.chapters[0], "The market square fills at dawn.")

        let hits = harness.library.searchNotes(query: "squar")
        #expect(hits.count == 1)
        #expect(hits[0].kind == .noteContent)
    }

    @Test("a chapter-title hit outranks a body hit")
    func titleHitOutranksBodyHit() throws {
        let harness = try Harness()
        // Chapter one's title contains "Introduction"; chapter two only has
        // the word in its note body. Title hits are pure navigation.
        try harness.saveNote(harness.chapters[1], "Introductions matter here.")

        let hits = harness.library.searchNotes(query: "introduct")
        #expect(hits.count == 2)
        #expect(hits[0].kind == .chapterTitle)
        #expect(hits[0].score > hits[1].score)
        #expect(hits[1].kind == .noteContent)
        #expect(hits[1].snippet.contains("Introductions"))
    }

    @Test("the phrase bonus ranks adjacent terms first")
    func phraseBonusRanksAdjacentTermsFirst() throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "Faith and doubt are twins.")
        try harness.saveNote(harness.chapters[1], "Faith doubt decided the night.")

        let hits = harness.library.searchNotes(query: "faith doubt")
        #expect(hits.count == 2)
        // Adjacent-in-order terms carry the phrase bonus.
        #expect(hits[0].score > hits[1].score)
        #expect(hits[0].chapterKey == "002")
    }

    @Test("snippet ranges are valid UTF-16 indices into the snippet")
    func snippetRangesAreValidUTF16() throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "Café culture thrives here.")

        let hits = harness.library.searchNotes(query: "café")
        #expect(hits.count == 1)
        #expect(!hits[0].snippetRanges.isEmpty)

        let units = Array(hits[0].snippet.utf16)
        for range in hits[0].snippetRanges {
            #expect(range.start < range.end)
            #expect(range.end <= units.count)
            let matched = String(decoding: units[range.start..<range.end], as: UTF16.self)
            #expect(matched.lowercased().hasPrefix("café"))
        }
    }

    @Test("a note edited outside the app is picked up on the next query")
    func externalEditIsPickedUp() async throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "original body text.")
        // Warm the index so the edit has to go through revalidation.
        #expect(!harness.library.searchNotes(query: "original").isEmpty)

        let notePath = try #require(
            try Files.contents(
                ofDirectory: harness.library.bookDir(harness.bookID)
                    .appendingPathComponent("notes/chapters")
            ).first { $0.hasSuffix(".md") }
        )
        // Ensure the mtime clearly differs from the indexed snapshot.
        try await Task.sleep(for: .milliseconds(20))
        try Files.write(
            Files.read(notePath).replacingOccurrences(of: "original", with: "xylophone"),
            to: notePath
        )

        #expect(!harness.library.searchNotes(query: "xylophone").isEmpty)
    }

    @Test("the warm index agrees with a cold scan")
    func warmIndexMatchesColdScan() throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "Faith and doubt are twins.")

        // Warm the index, then search again (exercises the validate path).
        _ = harness.library.searchNotes(query: "doubt")
        let warm = harness.library.searchNotes(query: "faith")

        let cold = SearchEngine().query(
            root: harness.root.appendingPathComponent("library").path, raw: "faith"
        )
        #expect(cold.count == warm.count)
        #expect(cold.first?.snippet == warm.first?.snippet)
        #expect(cold.first?.score == warm.first?.score)
    }

    @Test("a book-title-only match yields a single book target")
    func bookTitleOnlyMatch() throws {
        let harness = try Harness()
        // "Sample Book" is the fixture title; no chapter or note mentions it.
        let hits = harness.library.searchNotes(query: "sample")
        #expect(hits.count == 1)
        #expect(hits[0].kind == .bookTarget)
        #expect(hits[0].bookId == harness.bookID)
        #expect(hits[0].chapterKey.isEmpty)
        #expect(hits[0].bookTitle == "Sample Book")
    }

    @Test("a multi-term query requires every term")
    func multiTermQueryRequiresAllTerms() throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "Faith without doubt.")

        // AND semantics: a term that matches nothing kills the query, but
        // two scattered terms in the same note still match.
        #expect(harness.library.searchNotes(query: "faith xylophone").isEmpty)
        #expect(harness.library.searchNotes(query: "faith doubt").count == 1)
        #expect(harness.library.searchNotes(query: "faith").count == 1)
    }

    @Test("a removed book leaves the index on the next query")
    func removedBookLeavesTheIndex() throws {
        let harness = try Harness()
        try harness.saveNote(harness.chapters[0], "Faith and doubt are twins.")
        #expect(!harness.library.searchNotes(query: "faith").isEmpty)

        try harness.library.removeBook(id: harness.bookID)
        #expect(harness.library.searchNotes(query: "faith").isEmpty)
    }

    // MARK: Tokenizer

    @Test("tokens carry their UTF-16 ranges in the original text")
    func tokensCarryUTF16Ranges() {
        // An astral-plane character is two UTF-16 units; a token after it
        // must be offset accordingly or the UI highlights the wrong span.
        let text = "📚 café bar"
        let tokens = Tokenizer.tokenize(text)
        #expect(tokens.map(\.text) == ["café", "bar"])

        let units = Array(text.utf16)
        for token in tokens {
            #expect(
                String(decoding: units[token.start16..<token.end16], as: UTF16.self)
                    .lowercased() == token.text
            )
        }
    }

    @Test("a phrase match needs the terms adjacent and in order")
    func phraseMatchNeedsOrder() {
        let tokens = Tokenizer.tokenize("faith and doubt are twins")
        #expect(!tokens.isPhraseMatch(["faith", "doubt"]))
        #expect(tokens.isPhraseMatch(["and", "doubt"]))
        #expect(!tokens.isPhraseMatch(["doubt", "and"]))
        // A single term is never a phrase.
        #expect(!tokens.isPhraseMatch(["faith"]))
    }
}
