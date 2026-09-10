import Foundation

// The hand-written Swift core's data model (docs/apple-only-plan.md Phase 2
// step 2), replacing the UniFFI-generated records in MarginsCore. Type and
// property names match what the apps already call, so the swap in step 7 is
// a module rename rather than a rewrite of every call site.
//
// Two shapes meet here. On disk these types are the JSON/YAML records
// described in docs/storage.md, so the coding keys are snake_case and the
// encoders reproduce serde's field order, defaults, and omissions exactly —
// the Swift core has to read libraries the Rust core wrote. Facing the apps
// they are the bridge records, which is why `BookSummary`/`BookMeta` also
// carry the non-persisted `coverPath` the UI binds to.
//
// Differences from the Rust models, all deliberate:
//
// - Counts and indexes are `Int`, not `usize`/`u32`. The FFI widened them to
//   `UInt32`; Swift call sites are simpler with `Int`.
// - Timestamps are `Date`, not RFC3339 strings. UniFFI has no chrono type,
//   so the bridge stringified them and every consumer re-parsed; the core
//   now hands over real dates.
// - Every record is `Codable, Sendable, Equatable, Hashable`. Rust derived a
//   narrower set, but UniFFI synthesized all four on the generated records
//   and the apps rely on them.

// MARK: - Timestamps

/// RFC3339 codec for the timestamps in `meta.json`, `position.json`,
/// `_index.json`, and note frontmatter.
///
/// chrono's serde impl writes UTC with a `Z` suffix and `SecondsFormat::
/// AutoSi` precision, so files written by the Rust core carry 0, 3, 6, or 9
/// fractional digits. Parsing accepts all of them (and a numeric offset in
/// place of `Z`, which chrono's `to_rfc3339()` produced across the bridge);
/// writing always uses three digits.
public enum RFC3339 {
    private static let fractional = Date.ISO8601FormatStyle(
        dateTimeSeparator: .standard,
        timeZoneSeparator: .colon,
        includingFractionalSeconds: true
    )
    private static let whole = Date.ISO8601FormatStyle(
        dateTimeSeparator: .standard,
        timeZoneSeparator: .colon,
        includingFractionalSeconds: false
    )

    /// Writes UTC with `Z`, dropping the fractional field when it is zero —
    /// chrono's `SecondsFormat::AutoSi`, which is what produced the
    /// timestamps in docs/storage.md. Sub-second time is written to
    /// milliseconds; the Rust core wrote up to nanoseconds, so re-saving a
    /// file it wrote can shorten a timestamp without changing its meaning.
    public static func string(from date: Date) -> String {
        let formatted = fractional.format(date)
        guard let zeroFraction = formatted.range(of: ".000Z") else { return formatted }
        return formatted.replacingCharacters(in: zeroFraction, with: "Z")
    }

    /// Second precision, the form marks carry in their `at=` attribute
    /// (docs/storage.md). Sub-second time is truncated, not rounded, so the
    /// result matches chrono's `SecondsFormat::Secs`.
    public static func secondsString(from date: Date) -> String {
        whole.format(Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    /// The current time at the codec's own precision.
    ///
    /// `Date` is finer-grained than the three fractional digits written to
    /// disk, so a raw `Date()` would not compare equal to itself after a
    /// save and a re-read. Round-tripping it through the codec here means a
    /// timestamp the core stamps is exactly the timestamp callers read back.
    public static func now() -> Date {
        let now = Date()
        return date(from: string(from: now)) ?? now
    }

    public static func date(from raw: String) -> Date? {
        let normalized = normalizingFraction(raw)
        if let date = try? Date(normalized, strategy: fractional) { return date }
        return try? Date(normalized, strategy: whole)
    }

    /// Rewrites the fractional-seconds field to exactly three digits (or
    /// drops it), because `ISO8601FormatStyle` parses one width only.
    private static func normalizingFraction(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        var end = raw.index(after: dot)
        while end < raw.endIndex, raw[end].isASCII, raw[end].isNumber {
            end = raw.index(after: end)
        }
        let digits = raw[raw.index(after: dot)..<end]
        let head = raw[..<dot]
        let tail = raw[end...]
        if digits.isEmpty { return String(head + tail) }
        let millis = digits.prefix(3)
        let padding = String(repeating: "0", count: 3 - millis.count)
        return String(head) + "." + millis + padding + tail
    }
}

extension KeyedDecodingContainer {
    /// Decodes an RFC3339 timestamp, rejecting strings the codec cannot read
    /// rather than silently dropping the field.
    func decodeDate(forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        guard let date = RFC3339.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "not an RFC3339 timestamp: \(raw)"
            )
        }
        return date
    }

    /// Decodes an optional RFC3339 timestamp. A missing key, an explicit
    /// `null`, and an unparsable string all read as `nil`: these fields are
    /// display metadata, and a library written by an older build should
    /// still open.
    func decodeDateIfPresent(forKey key: Key) throws -> Date? {
        try decodeIfPresent(String.self, forKey: key).flatMap(RFC3339.date(from:))
    }
}

extension KeyedEncodingContainer {
    mutating func encodeDate(_ date: Date, forKey key: Key) throws {
        try encode(RFC3339.string(from: date), forKey: key)
    }

    mutating func encodeDateIfPresent(_ date: Date?, forKey key: Key) throws {
        try encodeIfPresent(date.map(RFC3339.string(from:)), forKey: key)
    }

    /// Writes a timestamp or an explicit `null`, for the fields serde left
    /// without `skip_serializing_if`.
    mutating func encodeDateOrNull(_ date: Date?, forKey key: Key) throws {
        if let date {
            try encode(RFC3339.string(from: date), forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

// MARK: - JSON

/// The library tree's JSON codec, matching `serde_json::to_string_pretty`
/// closely enough that the files stay readable and diff-friendly for the
/// humans and agents that traverse the library directly (docs/storage.md):
/// two-space indentation, `/` left unescaped.
///
/// One difference is unavoidable. `JSONEncoder` serializes a keyed container
/// from a dictionary, so the order `encode(to:)` writes fields in is not the
/// order they land in — the only stable choice is `.sortedKeys`. Files
/// therefore carry serde's key *names* but alphabetical key *order*, which
/// is why the parity harness compares JSON by value rather than by bytes
/// (docs/apple-only-plan.md Phase 2 step 6). Markdown, where byte identity
/// does matter, never goes through here.
public enum MarginsJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Books

/// A book as the library catalog (`index.json`) and the library list see it.
public struct BookSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var addedAt: Date
    public var chapterCount: Int
    public var notesCount: Int
    /// Cover image file name relative to the book directory (e.g.
    /// `cover.jpg`), or `nil` when the book has no cover. Stored relative so
    /// the library tree stays portable across machines and sync targets.
    public var cover: String?
    /// Absolute path of the cover image, resolved from the library root when
    /// the summary is handed to a caller. Never persisted.
    public var coverPath: String?
    /// Percent complete (0–100) from the book's reading position, or `nil`
    /// when the book was never opened.
    public var progressPercent: Double?

    public init(
        id: String,
        title: String,
        author: String,
        addedAt: Date,
        chapterCount: Int,
        notesCount: Int,
        cover: String? = nil,
        coverPath: String? = nil,
        progressPercent: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.addedAt = addedAt
        self.chapterCount = chapterCount
        self.notesCount = notesCount
        self.cover = cover
        self.coverPath = coverPath
        self.progressPercent = progressPercent
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author
        case addedAt = "added_at"
        case chapterCount = "chapter_count"
        case notesCount = "notes_count"
        case cover
        case progressPercent = "progress_percent"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        addedAt = try container.decodeDate(forKey: .addedAt)
        chapterCount = try container.decode(Int.self, forKey: .chapterCount)
        notesCount = try container.decode(Int.self, forKey: .notesCount)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        coverPath = nil
        progressPercent = try container.decodeIfPresent(Double.self, forKey: .progressPercent)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(author, forKey: .author)
        try container.encodeDate(addedAt, forKey: .addedAt)
        try container.encode(chapterCount, forKey: .chapterCount)
        try container.encode(notesCount, forKey: .notesCount)
        try container.encode(cover, forKey: .cover)
        try container.encode(progressPercent, forKey: .progressPercent)
    }
}

/// One spine item of a book, as stored in `meta.json`'s `chapters`.
public struct ChapterMeta: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Spine position, zero-padded. The anchor for note file names,
    /// `notes/_index.json`, note frontmatter, and `position.json`; it never
    /// changes for a given EPUB.
    public var key: String
    public var index: Int
    public var title: String
    /// In-zip path of the spine item, without a fragment. Both frontends
    /// match relocated hrefs against this, so it must stay a pure path.
    public var href: String
    /// Anchor id where this chapter starts inside `href`, taken from the
    /// book's TOC. `nil` when the TOC has no entry for the file (or there is
    /// no TOC).
    public var fragment: String?

    public init(key: String, index: Int, title: String, href: String, fragment: String? = nil) {
        self.key = key
        self.index = index
        self.title = title
        self.href = href
        self.fragment = fragment
    }

    public var id: String { key }

    /// Where the reader should land for this chapter: the chapter's TOC
    /// anchor when the book named one, otherwise the top of its file.
    /// `href` itself stays a pure path, because relocation events are
    /// matched against it.
    public var jumpTarget: String {
        guard let fragment, !fragment.isEmpty else { return href }
        return "\(href)#\(fragment)"
    }

    private enum CodingKeys: String, CodingKey {
        case key, index, title, href, fragment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        index = try container.decode(Int.self, forKey: .index)
        title = try container.decode(String.self, forKey: .title)
        href = try container.decode(String.self, forKey: .href)
        fragment = try container.decodeIfPresent(String.self, forKey: .fragment)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(index, forKey: .index)
        try container.encode(title, forKey: .title)
        try container.encode(href, forKey: .href)
        try container.encodeIfPresent(fragment, forKey: .fragment)
    }
}

/// A book's `meta.json`: identity, spine, and cover.
public struct BookMeta: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var language: String?
    public var addedAt: Date
    public var sourceFilename: String
    public var chapters: [ChapterMeta]
    /// Cover image file name relative to the book directory, or `nil` when
    /// the book has no cover.
    public var cover: String?
    /// Absolute path of the cover image, resolved from the library root when
    /// the record is handed to a caller. Never persisted.
    public var coverPath: String?
    /// Percent complete (0–100) joined from the book's reading position.
    /// Never persisted into `meta.json` — it lives in `position.json`.
    public var progressPercent: Double?
    /// Schema version of `chapters`. Absent (0) in books imported before
    /// TOC-derived titles existed; the library scan re-parses those and
    /// bumps the field.
    public var chaptersVersion: Int

    public init(
        id: String,
        title: String,
        author: String,
        language: String? = nil,
        addedAt: Date,
        sourceFilename: String,
        chapters: [ChapterMeta],
        cover: String? = nil,
        coverPath: String? = nil,
        progressPercent: Double? = nil,
        chaptersVersion: Int = 0
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.language = language
        self.addedAt = addedAt
        self.sourceFilename = sourceFilename
        self.chapters = chapters
        self.cover = cover
        self.coverPath = coverPath
        self.progressPercent = progressPercent
        self.chaptersVersion = chaptersVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author, language
        case addedAt = "added_at"
        case sourceFilename = "source_filename"
        case chapters, cover
        case progressPercent = "progress_percent"
        case chaptersVersion = "chapters_version"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        addedAt = try container.decodeDate(forKey: .addedAt)
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        chapters = try container.decode([ChapterMeta].self, forKey: .chapters)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        coverPath = nil
        progressPercent = try container.decodeIfPresent(Double.self, forKey: .progressPercent)
        chaptersVersion = try container.decodeIfPresent(Int.self, forKey: .chaptersVersion) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(author, forKey: .author)
        try container.encode(language, forKey: .language)
        try container.encodeDate(addedAt, forKey: .addedAt)
        try container.encode(sourceFilename, forKey: .sourceFilename)
        try container.encode(chapters, forKey: .chapters)
        try container.encode(cover, forKey: .cover)
        try container.encodeIfPresent(progressPercent, forKey: .progressPercent)
        try container.encode(chaptersVersion, forKey: .chaptersVersion)
    }
}

/// Where a reader left off in a book, stored as
/// `books/{book_id}/position.json` so it syncs with the library tree.
public struct ReadingPosition: Codable, Sendable, Equatable, Hashable {
    public var chapterKey: String
    /// Locates the exact page within the chapter; `nil` when unknown.
    public var epubCfi: String?
    /// Percent complete for the whole book, clamped to 0–100.
    public var percent: Double
    /// When the position was saved. Callers may leave this `nil` — the core
    /// stamps it on write — but it is always present on disk.
    public var updatedAt: Date?

    public init(chapterKey: String, epubCfi: String? = nil, percent: Double, updatedAt: Date? = nil) {
        self.chapterKey = chapterKey
        self.epubCfi = epubCfi
        self.percent = percent
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case chapterKey = "chapter_key"
        case epubCfi = "epub_cfi"
        case percent
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterKey = try container.decode(String.self, forKey: .chapterKey)
        epubCfi = try container.decodeIfPresent(String.self, forKey: .epubCfi)
        percent = try container.decode(Double.self, forKey: .percent)
        updatedAt = try container.decodeDateIfPresent(forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterKey, forKey: .chapterKey)
        try container.encodeIfPresent(epubCfi, forKey: .epubCfi)
        try container.encode(percent, forKey: .percent)
        try container.encodeDateIfPresent(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - Notes

/// Which chapter a note save targets, plus the CFI to record with it.
public struct ChapterRef: Codable, Sendable, Equatable, Hashable {
    public var key: String
    public var epubCfi: String?

    public init(key: String, epubCfi: String? = nil) {
        self.key = key
        self.epubCfi = epubCfi
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case epubCfi = "epub_cfi"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        epubCfi = try container.decodeIfPresent(String.self, forKey: .epubCfi)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(epubCfi, forKey: .epubCfi)
    }
}

/// The YAML frontmatter block of a chapter note file (docs/storage.md).
/// Field order here is emission order for the YAML codec.
public struct NoteFrontmatter: Codable, Sendable, Equatable, Hashable {
    public var bookId: String
    public var chapterKey: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var chapterHref: String
    public var epubCfi: String?
    public var kind: String
    /// Words in the long-form body only; marks are not counted.
    public var wordCount: Int
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        bookId: String,
        chapterKey: String,
        chapterIndex: Int,
        chapterTitle: String,
        chapterHref: String,
        epubCfi: String? = nil,
        kind: String,
        wordCount: Int,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.bookId = bookId
        self.chapterKey = chapterKey
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.chapterHref = chapterHref
        self.epubCfi = epubCfi
        self.kind = kind
        self.wordCount = wordCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case chapterKey = "chapter_key"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case chapterHref = "chapter_href"
        case epubCfi = "epub_cfi"
        case kind
        case wordCount = "word_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decode(String.self, forKey: .bookId)
        chapterKey = try container.decode(String.self, forKey: .chapterKey)
        chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
        chapterTitle = try container.decode(String.self, forKey: .chapterTitle)
        chapterHref = try container.decode(String.self, forKey: .chapterHref)
        epubCfi = try container.decodeIfPresent(String.self, forKey: .epubCfi)
        kind = try container.decode(String.self, forKey: .kind)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        createdAt = try container.decodeDateIfPresent(forKey: .createdAt)
        updatedAt = try container.decodeDateIfPresent(forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookId, forKey: .bookId)
        try container.encode(chapterKey, forKey: .chapterKey)
        try container.encode(chapterIndex, forKey: .chapterIndex)
        try container.encode(chapterTitle, forKey: .chapterTitle)
        try container.encode(chapterHref, forKey: .chapterHref)
        try container.encodeIfPresent(epubCfi, forKey: .epubCfi)
        try container.encode(kind, forKey: .kind)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encodeDateIfPresent(createdAt, forKey: .createdAt)
        try container.encodeDateIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// A quick, CFI-anchored note ("mark") stored inside the chapter note file's
/// marks section (docs/storage.md). `quote` is the quoted book selection
/// (empty when absent); `body` is the reader's thought (empty for pure
/// highlights). `cfi`/`percent` are `nil` for page-anchored marks with no
/// known position.
public struct Mark: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// 10 lowercase Crockford-base32 characters, time-ordered; stable for
    /// the mark's lifetime.
    public var id: String
    /// Range CFI of the selection, or `nil` for a page-anchored mark.
    public var cfi: String?
    /// When the mark was taken. Written to the file at second precision.
    public var at: Date
    /// Whole-book percent (0–100) at the mark's position, when known.
    public var percent: Double?
    public var quote: String
    public var body: String

    public init(
        id: String,
        cfi: String? = nil,
        at: Date,
        percent: Double? = nil,
        quote: String,
        body: String
    ) {
        self.id = id
        self.cfi = cfi
        self.at = at
        self.percent = percent
        self.quote = quote
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case id, cfi, at, percent, quote, body
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cfi = try container.decodeIfPresent(String.self, forKey: .cfi)
        at = try container.decodeDate(forKey: .at)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        quote = try container.decode(String.self, forKey: .quote)
        body = try container.decode(String.self, forKey: .body)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cfi, forKey: .cfi)
        try container.encodeDate(at, forKey: .at)
        try container.encode(percent, forKey: .percent)
        try container.encode(quote, forKey: .quote)
        try container.encode(body, forKey: .body)
    }
}

/// One chapter note file, parsed: frontmatter, long-form body, and marks.
public struct ChapterNote: Codable, Sendable, Equatable, Hashable {
    public var frontmatter: NoteFrontmatter
    /// The long-form note body only — everything above the
    /// `<!-- margins:marks -->` sentinel. Marks live in `marks`.
    public var body: String
    /// The chapter's marks, in file order.
    public var marks: [Mark]
    public var path: String

    public init(frontmatter: NoteFrontmatter, body: String, marks: [Mark], path: String) {
        self.frontmatter = frontmatter
        self.body = body
        self.marks = marks
        self.path = path
    }
}

// MARK: - Indexes

/// The library catalog, `{library_root}/index.json`. Regenerated by the
/// library scan; nothing reads it back.
public struct LibraryIndex: Codable, Sendable, Equatable, Hashable {
    public var books: [BookSummary]

    public init(books: [BookSummary]) {
        self.books = books
    }
}

/// A book's `notes/_index.json`.
public struct NotesIndex: Codable, Sendable, Equatable, Hashable {
    public var chapters: [NotesIndexEntry]

    public init(chapters: [NotesIndexEntry]) {
        self.chapters = chapters
    }
}

/// One entry of `notes/_index.json`. Carries the note's file name, which the
/// app-facing `NoteIndexEntry` drops.
public struct NotesIndexEntry: Codable, Sendable, Equatable, Hashable {
    public var chapterKey: String
    /// Note file name relative to `notes/`, e.g. `chapters/001-preface.md`.
    public var file: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var wordCount: Int
    /// Number of marks in the chapter's marks section. Absent (0) in indexes
    /// written before marks existed.
    public var markCount: Int
    public var updatedAt: Date?

    public init(
        chapterKey: String,
        file: String,
        chapterIndex: Int,
        chapterTitle: String,
        wordCount: Int,
        markCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.chapterKey = chapterKey
        self.file = file
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.wordCount = wordCount
        self.markCount = markCount
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case chapterKey = "chapter_key"
        case file
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case wordCount = "word_count"
        case markCount = "mark_count"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterKey = try container.decode(String.self, forKey: .chapterKey)
        file = try container.decode(String.self, forKey: .file)
        chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
        chapterTitle = try container.decode(String.self, forKey: .chapterTitle)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        markCount = try container.decodeIfPresent(Int.self, forKey: .markCount) ?? 0
        updatedAt = try container.decodeDateIfPresent(forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterKey, forKey: .chapterKey)
        try container.encode(file, forKey: .file)
        try container.encode(chapterIndex, forKey: .chapterIndex)
        try container.encode(chapterTitle, forKey: .chapterTitle)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(markCount, forKey: .markCount)
        try container.encodeDateOrNull(updatedAt, forKey: .updatedAt)
    }
}

/// A notes-index entry as the apps consume it: which chapters have notes,
/// with word and mark counts. Not persisted — the file name in
/// `NotesIndexEntry` is the core's business.
public struct NoteIndexEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var chapterKey: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var wordCount: Int
    public var markCount: Int
    public var updatedAt: Date?

    public init(
        chapterKey: String,
        chapterIndex: Int,
        chapterTitle: String,
        wordCount: Int,
        markCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.chapterKey = chapterKey
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.wordCount = wordCount
        self.markCount = markCount
        self.updatedAt = updatedAt
    }

    /// Drops the on-disk entry's file name.
    public init(_ entry: NotesIndexEntry) {
        self.init(
            chapterKey: entry.chapterKey,
            chapterIndex: entry.chapterIndex,
            chapterTitle: entry.chapterTitle,
            wordCount: entry.wordCount,
            markCount: entry.markCount,
            updatedAt: entry.updatedAt
        )
    }

    public var id: String { chapterKey }
}

// MARK: - Search

/// What a search hit points at. Chapter titles and book targets are pure
/// navigation; note-content hits carry a snippet.
public enum SearchHitKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case noteContent = "note-content"
    case chapterTitle = "chapter-title"
    case bookTarget = "book-target"
}

/// Half-open range of matched text, measured in UTF-16 code units of the
/// string it points into (snippet or title) so UI layers can convert it to
/// native string ranges without re-running the matcher.
public struct MatchRange: Codable, Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct NoteSearchHit: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var bookId: String
    public var bookTitle: String
    public var bookAuthor: String
    /// Empty for book-level targets.
    public var chapterKey: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var snippet: String
    public var wordCount: Int
    public var kind: SearchHitKind
    /// Deterministic relevance score; higher is better.
    public var score: Double
    /// Matched ranges within `snippet` (empty for non-content hits).
    public var snippetRanges: [MatchRange]
    /// Matched ranges within the displayed title (chapter title, or book
    /// title for book targets).
    public var titleRanges: [MatchRange]

    public init(
        bookId: String,
        bookTitle: String,
        bookAuthor: String,
        chapterKey: String,
        chapterIndex: Int,
        chapterTitle: String,
        snippet: String,
        wordCount: Int,
        kind: SearchHitKind,
        score: Double,
        snippetRanges: [MatchRange] = [],
        titleRanges: [MatchRange] = []
    ) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.chapterKey = chapterKey
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.snippet = snippet
        self.wordCount = wordCount
        self.kind = kind
        self.score = score
        self.snippetRanges = snippetRanges
        self.titleRanges = titleRanges
    }

    public var id: String { "\(bookId)/\(chapterKey)" }

    private enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case bookTitle = "book_title"
        case bookAuthor = "book_author"
        case chapterKey = "chapter_key"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case snippet
        case wordCount = "word_count"
        case kind, score
        case snippetRanges = "snippet_ranges"
        case titleRanges = "title_ranges"
    }
}

// MARK: - Compiled notes and export

/// Toggles for `renderMarkdown`; all default `true` unless noted.
public struct ExportOptions: Codable, Sendable, Equatable, Hashable {
    /// Linked table of contents after the header.
    public var includeToc: Bool
    /// Coverage/word-count summary line under the title.
    public var includeStats: Bool
    /// Default `false`; list note-less chapters as `_No note._` stubs so
    /// gaps stay visible.
    public var includeEmptyChapters: Bool
    /// Shift `#`/`##` inside note bodies down two levels so user headings
    /// never collide with the document's own `#`/`##` structure.
    public var demoteHeadings: Bool

    public init(
        includeToc: Bool = true,
        includeStats: Bool = true,
        includeEmptyChapters: Bool = false,
        demoteHeadings: Bool = true
    ) {
        self.includeToc = includeToc
        self.includeStats = includeStats
        self.includeEmptyChapters = includeEmptyChapters
        self.demoteHeadings = demoteHeadings
    }

    public static let `default` = ExportOptions()

    private enum CodingKeys: String, CodingKey {
        case includeToc = "include_toc"
        case includeStats = "include_stats"
        case includeEmptyChapters = "include_empty_chapters"
        case demoteHeadings = "demote_headings"
    }
}

/// One chapter section of a compiled notes page: the chapter's note, loaded
/// from disk. Note-less chapters are represented in `CompiledNotes`'
/// `emptyChapters` instead, with an empty body.
public struct CompiledChapter: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var chapterKey: String
    public var chapterIndex: Int
    public var chapterTitle: String
    /// Markdown, without frontmatter.
    public var body: String
    /// The chapter's marks in reading order (percent, then CFI, then id).
    public var marks: [Mark]
    public var wordCount: Int
    public var updatedAt: Date?

    public init(
        chapterKey: String,
        chapterIndex: Int,
        chapterTitle: String,
        body: String,
        marks: [Mark] = [],
        wordCount: Int,
        updatedAt: Date? = nil
    ) {
        self.chapterKey = chapterKey
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.body = body
        self.marks = marks
        self.wordCount = wordCount
        self.updatedAt = updatedAt
    }

    public var id: String { chapterKey }

    private enum CodingKeys: String, CodingKey {
        case chapterKey = "chapter_key"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case body, marks
        case wordCount = "word_count"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterKey = try container.decode(String.self, forKey: .chapterKey)
        chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
        chapterTitle = try container.decode(String.self, forKey: .chapterTitle)
        body = try container.decode(String.self, forKey: .body)
        marks = try container.decode([Mark].self, forKey: .marks)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        updatedAt = try container.decodeDateIfPresent(forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterKey, forKey: .chapterKey)
        try container.encode(chapterIndex, forKey: .chapterIndex)
        try container.encode(chapterTitle, forKey: .chapterTitle)
        try container.encode(body, forKey: .body)
        try container.encode(marks, forKey: .marks)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encodeDateOrNull(updatedAt, forKey: .updatedAt)
    }
}

/// Every chapter note of a book, compiled into one ordered document.
public struct CompiledNotes: Codable, Sendable, Equatable, Hashable {
    public var bookId: String
    public var bookTitle: String
    public var bookAuthor: String
    /// Chapters with notes, sorted by `chapterIndex`.
    public var chapters: [CompiledChapter]
    /// Spine chapters without a note file, sorted by `chapterIndex`.
    public var emptyChapters: [CompiledChapter]
    public var chaptersWithNotes: Int
    /// Total chapters in the book's spine.
    public var chapterCount: Int
    public var totalWords: Int
    public var firstCreatedAt: Date?
    public var lastUpdatedAt: Date?
    /// Shared default export name: `"{author} — {title} — notes.md"`,
    /// sanitized for filesystem use.
    public var suggestedFilename: String

    public init(
        bookId: String,
        bookTitle: String,
        bookAuthor: String,
        chapters: [CompiledChapter],
        emptyChapters: [CompiledChapter],
        chaptersWithNotes: Int,
        chapterCount: Int,
        totalWords: Int,
        firstCreatedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        suggestedFilename: String
    ) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.chapters = chapters
        self.emptyChapters = emptyChapters
        self.chaptersWithNotes = chaptersWithNotes
        self.chapterCount = chapterCount
        self.totalWords = totalWords
        self.firstCreatedAt = firstCreatedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.suggestedFilename = suggestedFilename
    }

    private enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case bookTitle = "book_title"
        case bookAuthor = "book_author"
        case chapters
        case emptyChapters = "empty_chapters"
        case chaptersWithNotes = "chapters_with_notes"
        case chapterCount = "chapter_count"
        case totalWords = "total_words"
        case firstCreatedAt = "first_created_at"
        case lastUpdatedAt = "last_updated_at"
        case suggestedFilename = "suggested_filename"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decode(String.self, forKey: .bookId)
        bookTitle = try container.decode(String.self, forKey: .bookTitle)
        bookAuthor = try container.decode(String.self, forKey: .bookAuthor)
        chapters = try container.decode([CompiledChapter].self, forKey: .chapters)
        emptyChapters = try container.decode([CompiledChapter].self, forKey: .emptyChapters)
        chaptersWithNotes = try container.decode(Int.self, forKey: .chaptersWithNotes)
        chapterCount = try container.decode(Int.self, forKey: .chapterCount)
        totalWords = try container.decode(Int.self, forKey: .totalWords)
        firstCreatedAt = try container.decodeDateIfPresent(forKey: .firstCreatedAt)
        lastUpdatedAt = try container.decodeDateIfPresent(forKey: .lastUpdatedAt)
        suggestedFilename = try container.decode(String.self, forKey: .suggestedFilename)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookId, forKey: .bookId)
        try container.encode(bookTitle, forKey: .bookTitle)
        try container.encode(bookAuthor, forKey: .bookAuthor)
        try container.encode(chapters, forKey: .chapters)
        try container.encode(emptyChapters, forKey: .emptyChapters)
        try container.encode(chaptersWithNotes, forKey: .chaptersWithNotes)
        try container.encode(chapterCount, forKey: .chapterCount)
        try container.encode(totalWords, forKey: .totalWords)
        try container.encodeDateOrNull(firstCreatedAt, forKey: .firstCreatedAt)
        try container.encodeDateOrNull(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encode(suggestedFilename, forKey: .suggestedFilename)
    }
}

// MARK: - Errors

/// Everything the core can fail with. The Rust build flattened its several
/// error enums into one UniFFI error carrying a message string; the cases
/// here restore the origin without changing what callers read, because
/// `errorDescription` is still the bare message.
public enum CoreError: Error, LocalizedError, Sendable, Equatable, Hashable {
    case config(String)
    case library(String)
    case notes(String)
    case epub(String)
    case io(String)
    case other(String)

    public var message: String {
        switch self {
        case let .config(message), let .library(message), let .notes(message),
             let .epub(message), let .io(message), let .other(message):
            return message
        }
    }

    public var errorDescription: String? { message }
}
