import Foundation

// In-memory search index over the library.
//
// Posture: the corpus is a personal library (hundreds of books, thousands of
// short notes), so a hand-rolled index is plenty.
//
// The index is built lazily on the first query and kept warm: every query
// re-validates each book cheaply (meta.json / notes/_index.json / note file
// mtimes) and re-parses only what changed, so notes edited by agents or
// external tools are picked up automatically. Saves through the core refresh
// their book eagerly.
//
// Matching is AND across whitespace-separated terms; every term matches as a
// token prefix (so "mark" finds "market" and results appear mid-word).
// Tokens are Unicode-case-folded. Ranking is deterministic: field weight
// (chapter title > book title/author > body) times term frequency, plus a
// phrase bonus when terms appear as adjacent tokens in order; ties break by
// book title, then chapter index.
//
// Highlight ranges are half-open and measured in UTF-16 code units of the
// string they point into (snippet or title), so UI layers can convert them
// to native string ranges without re-running the matcher.

/// The index. `Library` owns one and serializes access to it, so this is a
/// plain class rather than an actor: every entry point is already inside
/// `CoreStore`'s executor.
final class SearchEngine {
    private static let chapterTitleWeight = 3.0
    private static let bookTitleWeight = 2.0
    private static let authorWeight = 2.0
    private static let bodyWeight = 1.0
    private static let phraseBonus = 2.0

    /// Snippet window: characters of context before/after the first match.
    private static let snippetBefore = 40
    private static let snippetAfter = 80

    private var books: [String: IndexedBook] = [:]

    /// Drops all cached docs; the next query rebuilds from scratch.
    func clear() {
        books.removeAll()
    }

    /// Runs a query, first refreshing anything stale. Tolerates corrupt
    /// books and notes: they are skipped, never failing the whole search.
    func query(root: String, raw: String) -> [NoteSearchHit] {
        let terms = raw.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !terms.isEmpty else { return [] }
        validate(root: root)

        var hits: [NoteSearchHit] = []

        // Book-level targets: one hit per book whose title/author match.
        for book in books.values {
            let matchesAll = terms.allSatisfy { term in
                book.titleTokens.prefixMatches(term) > 0
                    || book.authorTokens.prefixMatches(term) > 0
            }
            guard matchesAll else { continue }

            var score = 0.0
            for term in terms {
                score += Self.bookTitleWeight * Double(book.titleTokens.prefixMatches(term))
                score += Self.authorWeight * Double(book.authorTokens.prefixMatches(term))
            }
            if book.titleTokens.isPhraseMatch(terms) || book.authorTokens.isPhraseMatch(terms) {
                score += Self.phraseBonus
            }
            hits.append(
                NoteSearchHit(
                    bookId: book.id,
                    bookTitle: book.title,
                    bookAuthor: book.author,
                    chapterKey: "",
                    chapterIndex: 0,
                    chapterTitle: "",
                    snippet: "",
                    wordCount: 0,
                    kind: .bookTarget,
                    score: score,
                    titleRanges: book.titleTokens.matchedRanges(terms)
                )
            )
        }

        // Chapter-level hits: every term must match within the chapter's own
        // title or note body. Body evidence makes it a content hit;
        // title-only matches are pure navigation targets.
        for (bookID, book) in books {
            for chapter in book.chapters {
                var titleFrequency = 0.0
                var bodyFrequency = 0.0
                let matchesAll = terms.allSatisfy { term in
                    let inTitle = chapter.titleTokens.prefixMatches(term)
                    let inBody = chapter.note?.bodyTokens.prefixMatches(term) ?? 0
                    titleFrequency += Double(inTitle)
                    bodyFrequency += Double(inBody)
                    return inTitle > 0 || inBody > 0
                }
                guard matchesAll else { continue }

                var score = Self.chapterTitleWeight * titleFrequency
                    + Self.bodyWeight * bodyFrequency
                if chapter.titleTokens.isPhraseMatch(terms)
                    || chapter.note?.bodyTokens.isPhraseMatch(terms) == true {
                    score += Self.phraseBonus
                }

                var kind = SearchHitKind.chapterTitle
                var snippet = ""
                var snippetRanges: [MatchRange] = []
                var wordCount = 0
                if bodyFrequency > 0, let note = chapter.note {
                    kind = .noteContent
                    (snippet, snippetRanges) = Self.buildSnippet(note.body, terms: terms)
                    wordCount = note.wordCount
                }

                hits.append(
                    NoteSearchHit(
                        bookId: bookID,
                        bookTitle: book.title,
                        bookAuthor: book.author,
                        chapterKey: chapter.key,
                        chapterIndex: chapter.index,
                        chapterTitle: chapter.title,
                        snippet: snippet,
                        wordCount: wordCount,
                        kind: kind,
                        score: score,
                        snippetRanges: snippetRanges,
                        titleRanges: chapter.titleTokens.matchedRanges(terms)
                    )
                )
            }
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.bookTitle != b.bookTitle { return a.bookTitle < b.bookTitle }
            if a.chapterIndex != b.chapterIndex { return a.chapterIndex < b.chapterIndex }
            return a.chapterKey < b.chapterKey
        }
        return hits
    }

    /// Re-reads one book from disk immediately (index update in place after
    /// a save). Corrupt data just drops the book from the index.
    func refreshBook(root: String, bookID: String) {
        books[bookID] = IndexedBook(
            bookDir: root.appendingPathComponent("books").appendingPathComponent(bookID)
        )
    }

    /// Cheap per-query validation: notice added/removed books, changed
    /// metadata, changed note indexes, and externally edited note bodies.
    private func validate(root: String) {
        let booksDir = root.appendingPathComponent("books")
        var present: Set<String> = []

        for bookDir in (try? Files.contents(ofDirectory: booksDir)) ?? [] {
            let id = (bookDir as NSString).lastPathComponent
            guard !id.hasPrefix("."), Files.isDirectory(bookDir),
                  let metaModified = Files.modificationDate(
                      bookDir.appendingPathComponent("meta.json")
                  )
            else { continue }
            present.insert(id)

            let notesIndexModified = Files.modificationDate(
                bookDir.appendingPathComponent("notes/_index.json")
            )
            let cached = books[id]
            let rebuild = cached == nil
                || cached!.metaModified != metaModified
                || cached!.notesIndexModified != notesIndexModified
            if rebuild {
                books[id] = IndexedBook(bookDir: bookDir)
                continue
            }

            // Index is structurally current; re-check note file bodies.
            guard var indexed = books[id] else { continue }
            for position in indexed.chapters.indices {
                guard let note = indexed.chapters[position].note else { continue }
                let path = bookDir.appendingPathComponent("notes")
                    .appendingPathComponent(note.file)
                guard let modified = Files.modificationDate(path), modified != note.modified,
                      let updated = IndexedNote(
                          path: path, file: note.file,
                          chapterKey: indexed.chapters[position].key
                      )
                else { continue }
                indexed.chapters[position].note = updated
            }
            books[id] = indexed
        }

        books = books.filter { present.contains($0.key) }
    }

    /// Builds a snippet window around the first term occurrence and collects
    /// the matched token ranges (UTF-16, relative to the snippet).
    private static func buildSnippet(
        _ body: String, terms: [String]
    ) -> (String, [MatchRange]) {
        let characters = Array(body)
        let tokens = Tokenizer.tokenize(body)
        guard let first = tokens.first(where: { token in
            terms.contains { token.text.hasPrefix($0) }
        }) else { return ("", []) }

        // The token's UTF-16 offset, converted to a character index.
        var matchStart = characters.count
        var utf16 = 0
        for (position, character) in characters.enumerated() {
            if utf16 >= first.start16 {
                matchStart = position
                break
            }
            utf16 += character.utf16.count
        }
        if matchStart > characters.count { matchStart = 0 }

        let start = max(matchStart - snippetBefore, 0)
        let end = min(matchStart + snippetAfter, characters.count)
        var snippet = String(characters[start..<end])
        if start > 0 { snippet = "…" + snippet }
        if end < characters.count { snippet += "…" }

        let ranges = Tokenizer.tokenize(snippet)
            .filter { token in terms.contains { token.text.hasPrefix($0) } }
            .map { MatchRange(start: $0.start16, end: $0.end16) }
        return (snippet, ranges)
    }
}

// MARK: - Indexed documents

private struct IndexedBook {
    var id: String
    var title: String
    var author: String
    var titleTokens: [Token]
    var authorTokens: [Token]
    var chapters: [IndexedChapter]
    var metaModified: Date
    var notesIndexModified: Date?

    init?(bookDir: String) {
        let metaPath = bookDir.appendingPathComponent("meta.json")
        guard let data = try? Files.readData(metaPath),
              let meta = try? MarginsJSON.decode(BookMeta.self, from: data),
              let metaModified = Files.modificationDate(metaPath)
        else { return nil }

        let notesIndexPath = bookDir.appendingPathComponent("notes/_index.json")
        let notesIndex = (try? Files.readData(notesIndexPath))
            .flatMap { try? MarginsJSON.decode(NotesIndex.self, from: $0) }
            ?? NotesIndex(chapters: [])
        let notesByKey = Dictionary(
            notesIndex.chapters.map { ($0.chapterKey, $0) }, uniquingKeysWith: { first, _ in first }
        )

        self.id = meta.id
        self.title = meta.title
        self.author = meta.author
        self.titleTokens = Tokenizer.tokenize(meta.title)
        self.authorTokens = Tokenizer.tokenize(meta.author)
        self.metaModified = metaModified
        self.notesIndexModified = Files.modificationDate(notesIndexPath)
        self.chapters = meta.chapters.map { chapter in
            IndexedChapter(
                key: chapter.key,
                index: chapter.index,
                title: chapter.title,
                titleTokens: Tokenizer.tokenize(chapter.title),
                note: notesByKey[chapter.key].flatMap { entry in
                    IndexedNote(
                        path: bookDir.appendingPathComponent("notes")
                            .appendingPathComponent(entry.file),
                        file: entry.file,
                        chapterKey: chapter.key
                    )
                }
            )
        }
    }
}

private struct IndexedChapter {
    var key: String
    var index: Int
    var title: String
    var titleTokens: [Token]
    /// The chapter note body, if a note exists.
    var note: IndexedNote?
}

private struct IndexedNote {
    var body: String
    var bodyTokens: [Token]
    var wordCount: Int
    /// The note's path relative to the book's `notes/` directory, as stored
    /// in the index.
    var file: String
    var modified: Date

    /// Parses a note file; a corrupt or deleted file yields `nil` (the
    /// chapter stays searchable by title).
    init?(path: String, file: String, chapterKey: String) {
        guard let note = try? Notes.parseNoteFile(path: path, chapterKey: chapterKey),
              let modified = Files.modificationDate(path)
        else { return nil }
        self.body = note.body
        self.bodyTokens = Tokenizer.tokenize(note.body)
        self.wordCount = note.frontmatter.wordCount
        self.file = file
        self.modified = modified
    }
}

// MARK: - Tokens

/// A word-ish run in a field, case-folded for matching, with its half-open
/// UTF-16 range in the original text.
struct Token {
    var text: String
    var start16: Int
    var end16: Int
}

enum Tokenizer {
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start16 = 0
        var utf16 = 0

        for character in text {
            if character.isLetter || character.isNumber {
                if current.isEmpty { start16 = utf16 }
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(Token(text: current.lowercased(), start16: start16, end16: utf16))
                current = ""
            }
            utf16 += character.utf16.count
        }
        if !current.isEmpty {
            tokens.append(Token(text: current.lowercased(), start16: start16, end16: utf16))
        }
        return tokens
    }
}

extension [Token] {
    func prefixMatches(_ term: String) -> Int {
        count { $0.text.hasPrefix(term) }
    }

    func matchedRanges(_ terms: [String]) -> [MatchRange] {
        filter { token in terms.contains { token.text.hasPrefix($0) } }
            .map { MatchRange(start: $0.start16, end: $0.end16) }
    }

    /// True when all terms appear, in order, as adjacent tokens (the last
    /// one may be a partial word — a query still being typed).
    func isPhraseMatch(_ terms: [String]) -> Bool {
        guard terms.count >= 2, count >= terms.count else { return false }
        for start in 0...(count - terms.count) {
            if terms.enumerated().allSatisfy({ self[start + $0.offset].text.hasPrefix($0.element) }) {
                return true
            }
        }
        return false
    }
}
