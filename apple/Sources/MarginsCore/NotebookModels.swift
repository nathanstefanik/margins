import Foundation

// Notebooks — long-running commonplace documents that gather passages
// (docs/commonplace.md "Notebook storage"). Each notebook is one
// `{root}/notebooks/{slug}.md` file: YAML frontmatter (id/title/
// created_at/updated_at) over a body of prose paragraphs and embedded
// passage blocks (`<!-- margins:passage … -->` + quote/citation `>` lines).

/// Catalog entry for one notebook; `file` is the filename inside
/// `{root}/notebooks/`. Stored in `notebooks/_index.json`.
public struct NotebookSummary: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var file: String
    public var passageCount: Int
    public var wordCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// True when the notebook file exists on this device only as an
    /// evicted iCloud placeholder — never persisted, recomputed at listing
    /// (like `BookSummary.coverPath`).
    public var isEvicted: Bool

    public init(
        id: String, title: String, file: String,
        passageCount: Int, wordCount: Int, createdAt: Date, updatedAt: Date,
        isEvicted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.file = file
        self.passageCount = passageCount
        self.wordCount = wordCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEvicted = isEvicted
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, file
        case passageCount = "passage_count"
        case wordCount = "word_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        file = try container.decode(String.self, forKey: .file)
        passageCount = try container.decode(Int.self, forKey: .passageCount)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        createdAt = try container.decodeDate(forKey: .createdAt)
        updatedAt = try container.decodeDate(forKey: .updatedAt)
        isEvicted = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(file, forKey: .file)
        try container.encode(passageCount, forKey: .passageCount)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encodeDate(createdAt, forKey: .createdAt)
        try container.encodeDate(updatedAt, forKey: .updatedAt)
    }
}

/// Which mark a passage block embeds.
public struct PassageRef: Codable, Sendable, Equatable, Hashable {
    public var bookId: String
    public var chapterKey: String
    public var markId: String

    public init(bookId: String, chapterKey: String, markId: String) {
        self.bookId = bookId
        self.chapterKey = chapterKey
        self.markId = markId
    }

    private enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case chapterKey = "chapter_key"
        case markId = "mark_id"
    }
}

/// Whether the passage's mark can still be found (docs/storage.md
/// resolution ladder).
public enum PassageStatus: String, Codable, Sendable, Equatable, Hashable {
    case ok
    case markMissing = "mark-missing"
    case bookMissing = "book-missing"
    case notDownloaded = "not-downloaded"
}

/// A passage resolved against the live library. `quote` is the live mark
/// quote (or body when the quote is empty) for `.ok`, else the block's
/// cached quote.
public struct PassageResolution: Codable, Sendable, Equatable, Hashable {
    public var status: PassageStatus
    public var quote: String
    public var bookTitle: String?
    public var bookAuthor: String?
    public var chapterTitle: String?
    public var cfi: String?
    public var percent: Double?
    public var markBody: String?

    public init(
        status: PassageStatus, quote: String,
        bookTitle: String? = nil, bookAuthor: String? = nil,
        chapterTitle: String? = nil, cfi: String? = nil,
        percent: Double? = nil, markBody: String? = nil
    ) {
        self.status = status
        self.quote = quote
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.chapterTitle = chapterTitle
        self.cfi = cfi
        self.percent = percent
        self.markBody = markBody
    }

    private enum CodingKeys: String, CodingKey {
        case status, quote
        case bookTitle = "book_title"
        case bookAuthor = "book_author"
        case chapterTitle = "chapter_title"
        case cfi, percent
        case markBody = "mark_body"
    }
}

/// One embedded passage block. `cachedQuote` is the quote text last
/// written to disk; `raw` is the block's exact on-disk bytes (nil for a
/// passage the UI created this session).
public struct NotebookPassage: Codable, Sendable, Equatable, Hashable {
    public var ref: PassageRef
    public var cachedQuote: String
    public var raw: String?
    public var resolution: PassageResolution

    public init(
        ref: PassageRef, cachedQuote: String, raw: String?, resolution: PassageResolution
    ) {
        self.ref = ref
        self.cachedQuote = cachedQuote
        self.raw = raw
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case ref
        case cachedQuote = "cached_quote"
        case raw, resolution
    }
}

/// One ordered segment of a notebook body: verbatim prose or an embedded
/// passage. `id` is stable per load ("s0", "s1", … by position); ids are
/// never persisted.
public struct NotebookSegment: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }

    public enum Content: Codable, Sendable, Equatable, Hashable {
        case prose(String)
        case passage(NotebookPassage)
    }
}

/// A notebook file fully loaded: catalog summary plus ordered segments.
public struct Notebook: Codable, Sendable, Equatable, Hashable {
    public var summary: NotebookSummary
    public var segments: [NotebookSegment]

    public init(summary: NotebookSummary, segments: [NotebookSegment]) {
        self.summary = summary
        self.segments = segments
    }
}

/// How a passage enters a notebook: an existing mark, or a reading
/// selection the core turns into a mark first (reusing one with the same
/// cfi, or the same quote when no cfi is given).
public enum PassageSource: Sendable, Hashable {
    case mark(bookId: String, chapterKey: String, markId: String)
    case selection(
        bookId: String, chapterKey: String, cfi: String?, percent: Double?, quote: String)
}
