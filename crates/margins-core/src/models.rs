use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSummary {
    pub id: String,
    pub title: String,
    pub author: String,
    pub added_at: DateTime<Utc>,
    pub chapter_count: usize,
    pub notes_count: usize,
    /// Cover image file name relative to the book directory (e.g.
    /// `cover.jpg`), or `None` when the book has no cover.
    #[serde(default)]
    pub cover: Option<String>,
    /// Percent complete (0–100) from the book's reading position, or `None`
    /// when the book was never opened.
    #[serde(default)]
    pub progress_percent: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterMeta {
    pub key: String,
    pub index: usize,
    pub title: String,
    /// In-zip path of the spine item, without a fragment. Both frontends
    /// match relocated hrefs against this, so it must stay a pure path.
    pub href: String,
    /// Anchor id where this chapter starts inside `href`, taken from the
    /// book's TOC. Jump targets are `href#fragment` when present; `None`
    /// when the TOC has no entry for the file (or there is no TOC).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fragment: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookMeta {
    pub id: String,
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub added_at: DateTime<Utc>,
    pub source_filename: String,
    pub chapters: Vec<ChapterMeta>,
    /// Cover image file name relative to the book directory (e.g.
    /// `cover.jpg`), or `None` when the book has no cover. Stored relative
    /// so the library tree stays portable across machines and sync targets.
    #[serde(default)]
    pub cover: Option<String>,
    /// Percent complete (0–100) joined from the book's reading position.
    /// Never persisted into `meta.json` — it lives in `position.json`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress_percent: Option<f64>,
    /// Schema version of `chapters`. Absent (0) in books imported before
    /// TOC-derived titles existed; the library scan re-parses those and
    /// bumps this to `CHAPTERS_VERSION`.
    #[serde(default)]
    pub chapters_version: u32,
}

/// Where a reader left off in a book, stored as
/// `books/{book_id}/position.json` so it syncs with the library tree.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingPosition {
    pub chapter_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epub_cfi: Option<String>,
    /// Percent complete for the whole book, clamped to 0–100.
    pub percent: f64,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterRef {
    pub key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub epub_cfi: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoteFrontmatter {
    pub book_id: String,
    pub chapter_key: String,
    pub chapter_index: usize,
    pub chapter_title: String,
    pub chapter_href: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub epub_cfi: Option<String>,
    pub kind: String,
    pub word_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
}

/// A quick, CFI-anchored note ("mark") stored inside the chapter note
/// file's marks section (see `docs/storage.md`). `quote` is the quoted
/// book selection (empty when absent); `body` is the reader's thought
/// (empty for pure highlights). `cfi`/`percent` are `None` for
/// page-anchored marks with no known position.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Mark {
    /// 10 lowercase Crockford-base32 characters, time-ordered; stable for
    /// the mark's lifetime.
    pub id: String,
    /// Range CFI of the selection, or `None` for a page-anchored mark.
    pub cfi: Option<String>,
    /// When the mark was taken.
    pub at: DateTime<Utc>,
    /// Whole-book percent (0–100) at the mark's position, when known.
    pub percent: Option<f64>,
    pub quote: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterNote {
    pub frontmatter: NoteFrontmatter,
    /// The long-form note body only — everything above the
    /// `<!-- margins:marks -->` sentinel. Marks live in `marks`.
    pub body: String,
    pub marks: Vec<Mark>,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryIndex {
    pub books: Vec<BookSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotesIndex {
    pub chapters: Vec<NotesIndexEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotesIndexEntry {
    pub chapter_key: String,
    pub file: String,
    pub chapter_index: usize,
    pub chapter_title: String,
    pub word_count: usize,
    /// Number of marks in the chapter's marks section. Absent (0) in
    /// indexes written before marks existed.
    #[serde(default)]
    pub mark_count: usize,
    pub updated_at: Option<DateTime<Utc>>,
}

/// What a search hit points at. Chapter titles and book targets are pure
/// navigation; note-content hits carry a snippet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SearchHitKind {
    NoteContent,
    ChapterTitle,
    BookTarget,
}

/// Half-open range of matched text, measured in UTF-16 code units of the
/// string it points into (snippet or title) so UI layers can convert it to
/// native string ranges without re-running the matcher.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MatchRange {
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoteSearchHit {
    pub book_id: String,
    pub book_title: String,
    pub book_author: String,
    pub chapter_key: String,
    pub chapter_index: usize,
    pub chapter_title: String,
    pub snippet: String,
    pub word_count: usize,
    pub kind: SearchHitKind,
    /// Deterministic relevance score; higher is better.
    pub score: f64,
    /// Matched ranges within `snippet` (empty for non-content hits).
    pub snippet_ranges: Vec<MatchRange>,
    /// Matched ranges within the displayed title (chapter title, or book
    /// title for book targets).
    pub title_ranges: Vec<MatchRange>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncReport {
    pub files_copied: usize,
    pub bytes_copied: u64,
    pub destination: String,
}

/// One chapter section of a compiled notes page: the chapter's note, loaded
/// from disk. Note-less chapters are represented in `CompiledNotes`'
/// `empty_chapters` instead, with an empty body.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompiledChapter {
    pub chapter_key: String,
    pub chapter_index: usize,
    pub chapter_title: String,
    /// Markdown, without frontmatter.
    pub body: String,
    /// The chapter's marks in reading order (percent, then CFI, then id).
    pub marks: Vec<Mark>,
    pub word_count: usize,
    pub updated_at: Option<DateTime<Utc>>,
}

/// Every chapter note of a book, compiled into one ordered document.
/// `chapters` holds the chapters that actually have notes (spine order);
/// `empty_chapters` mirrors the spine's note-less chapters so both UIs can
/// show gaps when asked.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompiledNotes {
    pub book_id: String,
    pub book_title: String,
    pub book_author: String,
    /// Chapters with notes, sorted by `chapter_index`.
    pub chapters: Vec<CompiledChapter>,
    /// Spine chapters without a note file, sorted by `chapter_index`.
    pub empty_chapters: Vec<CompiledChapter>,
    pub chapters_with_notes: usize,
    /// Total chapters in the book's spine.
    pub chapter_count: usize,
    pub total_words: usize,
    pub first_created_at: Option<DateTime<Utc>>,
    pub last_updated_at: Option<DateTime<Utc>>,
    /// Shared default export name: `"{author} — {title} — notes.md"`,
    /// sanitized for filesystem use.
    pub suggested_filename: String,
}

/// Toggles for `render_markdown`; all default `true` unless noted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExportOptions {
    /// Linked table of contents after the header.
    pub include_toc: bool,
    /// Coverage/word-count summary line under the title.
    pub include_stats: bool,
    /// Default `false`; list note-less chapters as `_No note._` stubs so
    /// gaps stay visible.
    pub include_empty_chapters: bool,
    /// Shift `#`/`##` inside note bodies down two levels so user headings
    /// never collide with the document's own `#`/`##` structure.
    pub demote_headings: bool,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            include_toc: true,
            include_stats: true,
            include_empty_chapters: false,
            demote_headings: true,
        }
    }
}
