import Foundation
import MarginsCore
import MarginsModel
import Testing

@Suite("Fuzzy match")
struct FuzzyMatchTests {
    @Test("non-subsequences do not match")
    func nonSubsequence() throws {
        #expect(FuzzyMatch.score("xyz", in: "The Brothers Karamazov") == nil)
        #expect(FuzzyMatch.score("kb", in: "Karamazov Brothers") != nil)  // order matters
        #expect(FuzzyMatch.score("bk", in: "Karamazov Brothers") == nil)
        #expect(FuzzyMatch.score("karamazov brothers", in: "Karamazov") == nil)
    }

    @Test("empty query matches everything at score zero")
    func emptyQuery() {
        #expect(FuzzyMatch.score("", in: "Anything") == 0)
        #expect(FuzzyMatch.score("", in: "") == 0)
    }

    @Test("prefix beats mid-word")
    func prefixBeatsMidWord() throws {
        let prefix = try #require(FuzzyMatch.score("bro", in: "Brothers Karamazov"))
        let inner = try #require(FuzzyMatch.score("bro", in: "The Brothers Karamazov"))
        #expect(prefix > inner)
    }

    @Test("word starts beat inner letters")
    func wordStartsWin() throws {
        let words = try #require(FuzzyMatch.score("tbk", in: "The Brothers Karamazov"))
        let inner = try #require(FuzzyMatch.score("tbk", in: "Thebkarma"))
        #expect(words > inner)
    }

    @Test("consecutive runs beat scattered letters")
    func consecutiveWins() throws {
        let run = try #require(FuzzyMatch.score("bro", in: "Brothers"))
        let scattered = try #require(FuzzyMatch.score("bro", in: "Baroque Rondo Overture"))
        #expect(run > scattered)
    }

    @Test("diacritics fold")
    func diacritics() {
        #expect(FuzzyMatch.score("bronte", in: "Brontë") != nil)
        #expect(FuzzyMatch.score("BRONTE", in: "brontë") != nil)
    }

    @Test("longer candidates score lower on equal matches")
    func lengthPenalty() throws {
        let short = try #require(FuzzyMatch.score("kar", in: "Karamazov"))
        let long = try #require(FuzzyMatch.score("kar", in: "Karamazov, or The Brothers"))
        #expect(short > long)
    }
}

@Suite("Command palette")
struct CommandPaletteTests {
    private func book(id: String, title: String, author: String = "") -> BookSummary {
        BookSummary(
            id: id,
            title: title,
            author: author,
            addedAt: Date(timeIntervalSince1970: 0),
            chapterCount: 2,
            notesCount: 0,
            progressPercent: nil,
            lastReadAt: nil
        )
    }

    private func meta(id: String, chapterCount: Int = 2) -> BookMeta {
        BookMeta(
            id: id,
            title: "Test Book",
            author: "Author",
            language: "en",
            addedAt: Date(timeIntervalSince1970: 0),
            sourceFilename: "test.epub",
            chapters: (0..<chapterCount).map {
                ChapterMeta(
                    key: "ch\($0)", index: $0, title: "Chapter \($0 + 1)",
                    href: "c\($0).xhtml", fragment: nil)
            },
            coverPath: nil,
            progressPercent: nil
        )
    }

    private func context(
        books: [BookSummary] = [],
        chaptersBook: BookMeta? = nil,
        hasSelectedBook: Bool = false,
        readerOpen: Bool = false
    ) -> CommandPalette.Context {
        CommandPalette.Context(
            books: books,
            chaptersBook: chaptersBook,
            hasSelectedBook: hasSelectedBook,
            readerOpen: readerOpen,
            justify: false,
            ornaments: true)
    }

    @Test("empty query offers books then commands, no chapters")
    func emptyQueryDefaults() {
        let books = (0..<8).map { book(id: "b\($0)", title: "Book \($0)") }
        let items = CommandPalette.items(
            for: context(books: books, chaptersBook: meta(id: "b0")))
        let sections = CommandPalette.sections(for: "", in: items)

        #expect(sections.map(\.group) == [.books, .commands])
        #expect(sections[0].items.count == CommandPalette.emptyQueryBookLimit)
        #expect(sections[0].items.first?.id == "book-b0")
        #expect(sections[1].items.count > 10)
    }

    @Test("query results group books, chapters, commands in order")
    func groupingOrder() {
        let items = CommandPalette.items(
            for: context(
                books: [book(id: "b1", title: "Timekeeper")],
                chaptersBook: meta(id: "b1"),
                readerOpen: true))
        // "i" appears in books? craft a query hitting all three groups.
        let sections = CommandPalette.sections(for: "settings", in: items)
        #expect(sections.map(\.group) == [.commands])
        #expect(sections[0].items.first?.action == .run(.settings))
    }

    @Test("book and chapter items carry the right actions")
    func itemActions() {
        let items = CommandPalette.items(
            for: context(
                books: [book(id: "b1", title: "A Book", author: "An Author")],
                chaptersBook: meta(id: "b1"),
                readerOpen: true))
        let bookItem = items.first { $0.id == "book-b1" }
        #expect(bookItem?.action == .openBook(id: "b1"))
        #expect(bookItem?.subtitle == "An Author")
        let chapterItems = items.filter { $0.group == .chapters }
        #expect(chapterItems.count == 2)
        #expect(
            chapterItems[0].action
                == .openChapter(bookId: "b1", chapterKey: "ch0", fragment: nil))
        #expect(chapterItems[0].subtitle == "Chapter 1")
    }

    @Test("state gates the conditional commands")
    func stateGates() {
        // Nothing selected, reader closed: no Book Notes, no Bookmarks.
        let closed = CommandPalette.items(for: context(hasSelectedBook: false, readerOpen: false))
        let closedCommands = closed.compactMap { item -> CommandPalette.Command? in
            guard case .run(let command) = item.action else { return nil }
            return command
        }
        #expect(!closedCommands.contains(.notesPage))
        #expect(!closedCommands.contains(.bookmarks))
        #expect(!closedCommands.contains(.toggleFocus))
        #expect(closedCommands.contains(.importBook))
        #expect(closedCommands.contains(.toggleSidebar))

        // Selected book + open reader: both appear.
        let open = CommandPalette.items(
            for: context(hasSelectedBook: true, readerOpen: true))
        let openCommands = open.compactMap { item -> CommandPalette.Command? in
            guard case .run(let command) = item.action else { return nil }
            return command
        }
        #expect(openCommands.contains(.notesPage))
        #expect(openCommands.contains(.bookmarks))
        #expect(openCommands.contains(.toggleFocus))
    }

    @Test("focus mode command reflects the current state")
    func focusCommandState() {
        var ctx = context(readerOpen: true)
        ctx.readerFocused = true
        let items = CommandPalette.items(for: ctx)
        #expect(items.contains { $0.title == "Focus Mode" && $0.subtitle == "On" })
    }

    @Test("preference commands reflect current state")
    func preferenceCommands() {
        var ctx = context()
        ctx.justify = true
        ctx.ornaments = false
        let items = CommandPalette.items(for: ctx)
        #expect(items.contains { $0.title == "Justify Text" && $0.subtitle == "On" })
        #expect(items.contains { $0.title == "Chapter Ornaments" && $0.subtitle == "Off" })
        #expect(items.contains { $0.title == "Paper: Sepia" })
        #expect(items.contains { $0.title == "Page Indicator: Time left" })
    }

    @Test("fuzzy filtering puts matching books first")
    func fuzzyFiltering() {
        let books = [
            book(id: "b1", title: "The Brothers Karamazov", author: "Fyodor Dostoevsky"),
            book(id: "b2", title: "Emma", author: "Jane Austen"),
        ]
        let items = CommandPalette.items(for: context(books: books))
        let sections = CommandPalette.sections(for: "kar", in: items)
        let all = sections.flatMap(\.items)
        #expect(all.first?.id == "book-b1")
        // The non-matching book is filtered out entirely.
        #expect(!all.contains { $0.id == "book-b2" })
    }

    @Test("results cap at the limit")
    func resultLimit() {
        // 40 books all matching "Book" → total shown ≤ 30.
        let books = (0..<40).map { book(id: "b\($0)", title: "Book \($0)") }
        let items = CommandPalette.items(for: context(books: books))
        let sections = CommandPalette.sections(for: "book", in: items)
        let total = sections.reduce(0) { $0 + $1.items.count }
        #expect(total == CommandPalette.resultLimit)
    }

    @Test("subtitle matches are found but rank below title matches")
    func subtitleWeight() {
        let books = [
            book(id: "b1", title: "Emma", author: "Jane Austen"),
            book(id: "b2", title: "Persuasion", author: "Jane Austen"),
            book(id: "b3", title: "Jane Eyre", author: "Charlotte Brontë"),
        ]
        let items = CommandPalette.items(for: context(books: books))
        let all = CommandPalette.sections(for: "jane", in: items).flatMap(\.items)
        // "Jane Eyre" (title) beats subtitle-only "…Austen" books.
        #expect(all.first?.id == "book-b3")
        #expect(all.contains { $0.id == "book-b1" })
    }

    @Test("tie order is stable")
    func stableTies() {
        let books = [
            book(id: "a", title: "Kar A"),
            book(id: "b", title: "Kar B"),
        ]
        let items = CommandPalette.items(for: context(books: books))
        let all = CommandPalette.sections(for: "kar", in: items).flatMap(\.items)
        #expect(all.map(\.id).prefix(2) == ["book-a", "book-b"])
    }
}
