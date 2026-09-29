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
// Matching is AND across whitespace-separated terms; a term matches a
// token by folded prefix (so "mark" finds "market") or by equal Porter2
// stem (so "deceive" finds "deceived"). Tokens are case- and
// diacritic-folded ("café" finds "Café"). A term that matched nothing in
// the corpus is expanded once by edit distance ("decieved" → "deceived").
// Ranking is deterministic: field weight (chapter title > book
// title/author > body) times term frequency, plus a phrase bonus when
// terms appear as adjacent tokens in order; ties break by book title,
// then chapter index.
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

    /// Typo fallback: a term this short is never expanded; below the long
    /// threshold the distance limit is 1, at/above it 2.
    private static let typoMinLength = 4
    private static let typoLongLength = 8

    /// Snippet window: characters of context before/after the first match.
    private static let snippetBefore = 40
    private static let snippetAfter = 80

    private var books: [String: IndexedBook] = [:]
    private var notebooks: [String: IndexedNotebook] = [:]
    /// The typo fallback's corpus, cached across queries and dropped
    /// whenever validate/refresh actually changes a doc (or clear()).
    private var vocabulary: (folded: Set<String>, stems: Set<String>)?

    /// Drops all cached docs; the next query rebuilds from scratch.
    func clear() {
        books.removeAll()
        notebooks.removeAll()
        vocabulary = nil
    }

    /// Runs a query, first refreshing anything stale. Tolerates corrupt
    /// books and notes: they are skipped, never failing the whole search.
    func query(root: String, raw: String) -> [NoteSearchHit] {
        let terms = raw.split(whereSeparator: \.isWhitespace)
            .compactMap { TextAnalyzer.analyzeTerm(String($0)) }
        guard !terms.isEmpty else { return [] }
        validate(root: root)
        return collectHits(terms: expandUnmatched(terms))
    }

    /// Re-reads one book from disk immediately (index update in place after
    /// a save). Corrupt data just drops the book from the index.
    func refreshBook(root: String, bookID: String) {
        books[bookID] = IndexedBook(
            bookDir: root.appendingPathComponent("books").appendingPathComponent(bookID)
        )
        vocabulary = nil
    }

    /// Re-reads the notebooks directory immediately (index update in place
    /// after a notebook write).
    func refreshNotebooks(root: String) {
        validateNotebooks(root: root)
    }

    /// The corpus the typo fallback expands against: every folded token
    /// and stem the index holds. Cached; the rebuild only runs when a doc
    /// actually changed.
    private func corpusVocabulary() -> (folded: Set<String>, stems: Set<String>) {
        if let vocabulary { return vocabulary }
        let built = buildVocabulary()
        vocabulary = built
        return built
    }

    private func buildVocabulary() -> (folded: Set<String>, stems: Set<String>) {
        var folded: Set<String> = []
        var stems: Set<String> = []
        func take(_ tokens: [Token]) {
            for token in tokens {
                folded.insert(token.folded)
                stems.insert(token.stem)
            }
        }
        for book in books.values {
            take(book.titleTokens)
            take(book.authorTokens)
            for chapter in book.chapters {
                take(chapter.titleTokens)
                if let note = chapter.note {
                    take(note.bodyTokens)
                    for mark in note.marks { take(mark.tokens) }
                }
            }
        }
        for notebook in notebooks.values {
            take(notebook.titleTokens)
            take(notebook.proseTokens)
        }
        return (folded, stems)
    }

    /// A term that matched nothing anywhere (prefix or stem) and is long
    /// enough to be a plausible word is replaced by the corpus tokens
    /// within edit distance 1 (4–7 characters) or 2 (8+). A term that
    /// matched something is never expanded.
    private func expandUnmatched(_ terms: [AnalyzedToken]) -> [[AnalyzedToken]] {
        let vocabulary = corpusVocabulary()
        return terms.map { term in
            guard term.folded.count >= Self.typoMinLength else { return [term] }
            let matched =
                vocabulary.stems.contains(term.stem)
                || vocabulary.folded.contains { $0.hasPrefix(term.folded) }
            guard !matched else { return [term] }
            let limit = term.folded.count >= Self.typoLongLength ? 2 : 1
            let alternatives = vocabulary.folded
                .filter { EditDistance.osa(term.folded, $0, limit: limit) != nil }
                .compactMap { TextAnalyzer.analyzeTerm($0) }
            return alternatives.isEmpty ? [term] : alternatives
        }
    }

    private func collectHits(terms: [[AnalyzedToken]]) -> [NoteSearchHit] {
        var hits: [NoteSearchHit] = []

        // Book-level targets: one hit per book whose title/author match.
        for book in books.values {
            let matchesAll = terms.allSatisfy { alternatives in
                book.titleTokens.termMatches(alternatives) > 0
                    || book.authorTokens.termMatches(alternatives) > 0
            }
            guard matchesAll else { continue }

            var score = 0.0
            for alternatives in terms {
                score += Self.bookTitleWeight * Double(book.titleTokens.termMatches(alternatives))
                score += Self.authorWeight * Double(book.authorTokens.termMatches(alternatives))
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
                let matchesAll = terms.allSatisfy { alternatives in
                    let inTitle = chapter.titleTokens.termMatches(alternatives)
                    let inBody = chapter.note?.bodyTokens.termMatches(alternatives) ?? 0
                    titleFrequency += Double(inTitle)
                    bodyFrequency += Double(inBody)
                    return inTitle > 0 || inBody > 0
                }
                if matchesAll {
                    var score =
                        Self.chapterTitleWeight * titleFrequency
                        + Self.bodyWeight * bodyFrequency
                    if chapter.titleTokens.isPhraseMatch(terms)
                        || chapter.note?.bodyTokens.isPhraseMatch(terms) == true
                    {
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

                // Each mark is its own document (quote + body), a hit of
                // kind `mark` carrying the mark id and cfi.
                for mark in chapter.note?.marks ?? [] {
                    let matchesAll = terms.allSatisfy { alternatives in
                        mark.tokens.termMatches(alternatives) > 0
                    }
                    guard matchesAll else { continue }

                    var score = 0.0
                    for alternatives in terms {
                        score += Self.bodyWeight * Double(mark.tokens.termMatches(alternatives))
                    }
                    if mark.tokens.isPhraseMatch(terms) { score += Self.phraseBonus }

                    let (snippet, snippetRanges) = Self.buildSnippet(mark.text, terms: terms)
                    hits.append(
                        NoteSearchHit(
                            bookId: bookID,
                            bookTitle: book.title,
                            bookAuthor: book.author,
                            chapterKey: chapter.key,
                            chapterIndex: chapter.index,
                            chapterTitle: chapter.title,
                            snippet: snippet,
                            wordCount: 0,
                            kind: .mark,
                            score: score,
                            snippetRanges: snippetRanges,
                            titleRanges: chapter.titleTokens.matchedRanges(terms),
                            markId: mark.id,
                            cfi: mark.cfi
                        )
                    )
                }
            }
        }

        // Each notebook's prose is one document (passage blocks are already
        // indexed as marks). The notebook title rides as the chapter title.
        for notebook in notebooks.values {
            var titleFrequency = 0.0
            var proseFrequency = 0.0
            let matchesAll = terms.allSatisfy { alternatives in
                let inTitle = notebook.titleTokens.termMatches(alternatives)
                let inProse = notebook.proseTokens.termMatches(alternatives)
                titleFrequency += Double(inTitle)
                proseFrequency += Double(inProse)
                return inTitle > 0 || inProse > 0
            }
            guard matchesAll else { continue }

            var score =
                Self.chapterTitleWeight * titleFrequency
                + Self.bodyWeight * proseFrequency
            if notebook.titleTokens.isPhraseMatch(terms)
                || notebook.proseTokens.isPhraseMatch(terms)
            {
                score += Self.phraseBonus
            }

            var snippet = ""
            var snippetRanges: [MatchRange] = []
            if proseFrequency > 0 {
                (snippet, snippetRanges) = Self.buildSnippet(notebook.prose, terms: terms)
            }
            hits.append(
                NoteSearchHit(
                    bookId: "",
                    bookTitle: "",
                    bookAuthor: "",
                    chapterKey: "",
                    chapterIndex: 0,
                    chapterTitle: notebook.title,
                    snippet: snippet,
                    wordCount: 0,
                    kind: .notebook,
                    score: score,
                    snippetRanges: snippetRanges,
                    titleRanges: notebook.titleTokens.matchedRanges(terms),
                    notebookId: notebook.id
                )
            )
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.bookTitle != b.bookTitle { return a.bookTitle < b.bookTitle }
            if a.chapterIndex != b.chapterIndex { return a.chapterIndex < b.chapterIndex }
            return a.chapterKey < b.chapterKey
        }
        return hits
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
            let rebuild =
                cached == nil
                || cached!.metaModified != metaModified
                || cached!.notesIndexModified != notesIndexModified
            if rebuild {
                books[id] = IndexedBook(bookDir: bookDir)
                vocabulary = nil
                continue
            }

            // Index is structurally current; re-check note file bodies.
            guard var indexed = books[id] else { continue }
            var noteChanged = false
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
                noteChanged = true
            }
            if noteChanged {
                books[id] = indexed
                vocabulary = nil
            }
        }

        let bookCount = books.count
        books = books.filter { present.contains($0.key) }
        if books.count != bookCount { vocabulary = nil }
        validateNotebooks(root: root)
    }

    /// The notebooks half of validation: per-file mtimes under
    /// `notebooks/`. A file that fails to parse or lacks an mtime (an
    /// evicted placeholder) simply drops out until it reads cleanly.
    private func validateNotebooks(root: String) {
        let dir = root.appendingPathComponent("notebooks")
        var present: Set<String> = []
        for path in (try? Files.contents(ofDirectory: dir)) ?? []
        where path.hasSuffix(".md") && Files.isFile(path) {
            let name = (path as NSString).lastPathComponent
            guard let modified = Files.modificationDate(path) else { continue }
            present.insert(name)
            guard notebooks[name]?.modified != modified else { continue }
            notebooks[name] = IndexedNotebook(path: path, file: name)
            vocabulary = nil
        }
        let notebookCount = notebooks.count
        notebooks = notebooks.filter { present.contains($0.key) }
        if notebooks.count != notebookCount { vocabulary = nil }
    }

    /// Builds a snippet window around the first term occurrence and collects
    /// the matched token ranges (UTF-16, relative to the snippet).
    private static func buildSnippet(
        _ body: String, terms: [[AnalyzedToken]]
    ) -> (String, [MatchRange]) {
        let characters = Array(body)
        let tokens = Tokenizer.tokenize(body)
        guard
            let first = tokens.first(where: { token in
                terms.contains { token.matchesAnyOf($0) }
            })
        else { return ("", []) }

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
            .filter { token in terms.contains { token.matchesAnyOf($0) } }
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
        let notesIndex =
            (try? Files.readData(notesIndexPath))
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
    /// Each mark indexed as its own document: quote + body.
    var marks: [IndexedMark]
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
        self.marks = note.marks.map(IndexedMark.init(mark:))
        self.wordCount = note.frontmatter.wordCount
        self.file = file
        self.modified = modified
    }
}

/// One mark's text (quote + body) with its id/cfi for hit identity and
/// jump-to-context.
private struct IndexedMark {
    var id: String
    var cfi: String?
    var text: String
    var tokens: [Token]

    init(mark: Mark) {
        id = mark.id
        cfi = mark.cfi
        text = mark.quote + "\n" + mark.body
        tokens = Tokenizer.tokenize(text)
    }
}

/// One notebook's prose (passage blocks are already indexed as marks),
/// revalidated by file mtime like a note.
private struct IndexedNotebook {
    var id: String
    var title: String
    var titleTokens: [Token]
    var prose: String
    var proseTokens: [Token]
    var file: String
    var modified: Date

    /// Parses a notebook file; a corrupt one yields `nil` (it simply drops
    /// out of the index until it parses). Reads stay uncoordinated (plain
    /// `Files`), like the note reads — this cache must tolerate a file
    /// disappearing mid-scan rather than coordinate around it.
    init?(path: String, file: String) {
        guard let raw = try? Files.read(path),
            let parsed = try? Notebooks.parseContent(raw),
            let modified = Files.modificationDate(path)
        else { return nil }
        let prose = parsed.segments.compactMap { segment -> String? in
            guard case .prose(let text) = segment.content else { return nil }
            return text
        }.joined()
        self.id = parsed.frontmatter.id
        self.title = parsed.frontmatter.title
        self.titleTokens = Tokenizer.tokenize(parsed.frontmatter.title)
        self.prose = prose
        self.proseTokens = Tokenizer.tokenize(prose)
        self.file = file
        self.modified = modified
    }
}

// MARK: - Tokens

/// A word-ish run in a field: `text` is the lowercased original (kept for
/// range/identity tests), `folded` and `stem` are what matching reads —
/// folded is case- and diacritic-insensitive with possessives dropped
/// ("café" → "cafe", "don't" → "dont"), and the stem is Porter2 for
/// ASCII-letter tokens, else the folded form. `start16`/`end16` are the
/// half-open UTF-16 range in the original text.
struct Token {
    var text: String
    var folded: String
    var stem: String
    var start16: Int
    var end16: Int
}

enum Tokenizer {
    /// Tokenizes with the shared pipeline (TextAnalysis.swift): runs of
    /// letters and digits, an internal apostrophe between letters stays.
    /// `Token.text` is the original slice lowercased — readable and exactly
    /// what the UTF-16 range spans.
    static func tokenize(_ text: String) -> [Token] {
        let units = Array(text.utf16)
        return TextAnalyzer.tokens(text).map { token in
            Token(
                text: String(decoding: units[token.start16..<token.end16], as: UTF16.self)
                    .lowercased(),
                folded: token.folded, stem: token.stem,
                start16: token.start16, end16: token.end16
            )
        }
    }
}

extension Token {
    /// A token matches a query term by folded prefix (today's rule) or by
    /// equal Porter2 stem.
    func matches(_ term: AnalyzedToken) -> Bool {
        folded.hasPrefix(term.folded) || stem == term.stem
    }
}

extension [Token] {
    /// Matches when ANY alternative in the set matches (a typo-expanded
    /// term); one-element sets are the common case.
    func termMatches(_ alternatives: [AnalyzedToken]) -> Int {
        count { token in alternatives.contains { token.matches($0) } }
    }

    func matchedRanges(_ alternatives: [[AnalyzedToken]]) -> [MatchRange] {
        filter { token in alternatives.contains { token.matchesAnyOf($0) } }
            .map { MatchRange(start: $0.start16, end: $0.end16) }
    }

    /// True when all term sets appear, in order, as adjacent tokens (the
    /// last one may be a partial word — a query still being typed).
    func isPhraseMatch(_ alternatives: [[AnalyzedToken]]) -> Bool {
        guard alternatives.count >= 2, count >= alternatives.count else { return false }
        for start in 0...(count - alternatives.count) {
            if alternatives.enumerated().allSatisfy({
                self[start + $0.offset].matchesAnyOf($0.element)
            }) {
                return true
            }
        }
        return false
    }

    // String-term variants kept for direct unit tests of the tokenizer.
    func prefixMatches(_ term: String) -> Int {
        count { $0.text.hasPrefix(term) }
    }

    func matchedRanges(_ terms: [String]) -> [MatchRange] {
        filter { token in terms.contains { token.text.hasPrefix($0) } }
            .map { MatchRange(start: $0.start16, end: $0.end16) }
    }

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

private extension Token {
    func matchesAnyOf(_ alternatives: [AnalyzedToken]) -> Bool {
        alternatives.contains { matches($0) }
    }
}
