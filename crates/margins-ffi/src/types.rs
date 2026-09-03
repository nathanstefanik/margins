use chrono::{DateTime, Utc};
use margins_core::library::Library;
use margins_core::models;

#[derive(uniffi::Record)]
pub struct BookSummary {
    pub id: String,
    pub title: String,
    pub author: String,
    pub added_at: String,
    pub chapter_count: u32,
    pub notes_count: u32,
    /// Absolute path of the cover image file, or `None` when the book has
    /// none. Resolved from the library root at call time.
    pub cover_path: Option<String>,
    /// Percent complete (0–100), or `None` when the book was never opened.
    pub progress_percent: Option<f64>,
}

#[derive(uniffi::Record)]
pub struct ChapterMeta {
    pub key: String,
    pub index: u32,
    pub title: String,
    /// In-zip path of the spine item, never carrying a fragment.
    pub href: String,
    /// Anchor id where the chapter starts inside `href`, from the book's
    /// TOC. Jump targets are `href#fragment` when present.
    pub fragment: Option<String>,
}

#[derive(uniffi::Record)]
pub struct BookMeta {
    pub id: String,
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub added_at: String,
    pub source_filename: String,
    pub chapters: Vec<ChapterMeta>,
    /// Absolute path of the cover image file, or `None` when the book has
    /// none. Resolved from the library root at call time.
    pub cover_path: Option<String>,
    /// Percent complete (0–100), or `None` when the book was never opened.
    pub progress_percent: Option<f64>,
}

/// Where a reader left off in a book. Saved through the core into the
/// library tree (`books/{book_id}/position.json`) so it syncs like
/// everything else; `updated_at` is set by the core on save.
#[derive(uniffi::Record)]
pub struct ReadingPosition {
    pub chapter_key: String,
    pub epub_cfi: Option<String>,
    pub percent: f64,
    pub updated_at: Option<String>,
}

impl ReadingPosition {
    pub fn from_core(value: models::ReadingPosition) -> Self {
        Self {
            chapter_key: value.chapter_key,
            epub_cfi: value.epub_cfi,
            percent: value.percent,
            updated_at: Some(rfc3339(value.updated_at)),
        }
    }

    pub fn into_core(self) -> models::ReadingPosition {
        models::ReadingPosition {
            chapter_key: self.chapter_key,
            epub_cfi: self.epub_cfi,
            percent: self.percent,
            // The core stamps the save time itself; any caller value is
            // advisory only.
            updated_at: self
                .updated_at
                .and_then(|t| DateTime::parse_from_rfc3339(&t).ok())
                .map(|t| t.with_timezone(&Utc))
                .unwrap_or_else(Utc::now),
        }
    }
}

#[derive(uniffi::Record)]
pub struct ChapterRef {
    pub key: String,
    pub epub_cfi: Option<String>,
}

#[derive(uniffi::Record)]
pub struct NoteFrontmatter {
    pub book_id: String,
    pub chapter_key: String,
    pub chapter_index: u32,
    pub chapter_title: String,
    pub chapter_href: String,
    pub epub_cfi: Option<String>,
    pub kind: String,
    pub word_count: u32,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(uniffi::Record)]
pub struct ChapterNote {
    pub frontmatter: NoteFrontmatter,
    pub body: String,
    pub path: String,
}

/// One entry of a book's `notes/_index.json`: which chapters have notes.
#[derive(uniffi::Record)]
pub struct NoteIndexEntry {
    pub chapter_key: String,
    pub chapter_index: u32,
    pub chapter_title: String,
    pub word_count: u32,
    pub updated_at: Option<String>,
}

/// Kind of search hit; mirrors the core's `SearchHitKind`.
#[derive(uniffi::Enum)]
pub enum SearchHitKind {
    NoteContent,
    ChapterTitle,
    BookTarget,
}

/// Half-open match range in UTF-16 code units of the string it points into.
#[derive(uniffi::Record)]
pub struct MatchRange {
    pub start: u32,
    pub end: u32,
}

#[derive(uniffi::Record)]
pub struct NoteSearchHit {
    pub book_id: String,
    pub book_title: String,
    pub book_author: String,
    /// Empty for book-level targets.
    pub chapter_key: String,
    pub chapter_index: u32,
    pub chapter_title: String,
    pub snippet: String,
    pub word_count: u32,
    pub kind: SearchHitKind,
    /// Deterministic relevance score; higher is better.
    pub score: f64,
    /// Matched ranges within `snippet` (UTF-16, half-open).
    pub snippet_ranges: Vec<MatchRange>,
    /// Matched ranges within the displayed title (UTF-16, half-open).
    pub title_ranges: Vec<MatchRange>,
}

fn rfc3339(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339()
}

impl BookSummary {
    /// Converts a core summary, resolving the cover to an absolute path via
    /// the library root.
    pub fn from_core(value: models::BookSummary, library: &Library) -> Self {
        let cover_path = resolve_cover(library, &value.id, value.cover);
        Self {
            id: value.id,
            title: value.title,
            author: value.author,
            added_at: rfc3339(value.added_at),
            chapter_count: value.chapter_count as u32,
            notes_count: value.notes_count as u32,
            cover_path,
            progress_percent: value.progress_percent,
        }
    }
}

impl From<models::ChapterMeta> for ChapterMeta {
    fn from(value: models::ChapterMeta) -> Self {
        Self {
            key: value.key,
            index: value.index as u32,
            title: value.title,
            href: value.href,
            fragment: value.fragment,
        }
    }
}

impl BookMeta {
    /// Converts a core record, resolving the cover to an absolute path via
    /// the library root.
    pub fn from_core(value: models::BookMeta, library: &Library) -> Self {
        let cover_path = resolve_cover(library, &value.id, value.cover);
        Self {
            id: value.id,
            title: value.title,
            author: value.author,
            language: value.language,
            added_at: rfc3339(value.added_at),
            source_filename: value.source_filename,
            chapters: value.chapters.into_iter().map(Into::into).collect(),
            cover_path,
            progress_percent: value.progress_percent,
        }
    }
}

fn resolve_cover(library: &Library, book_id: &str, cover: Option<String>) -> Option<String> {
    cover.map(|name| library.book_dir(book_id).join(name).display().to_string())
}

impl From<models::NoteFrontmatter> for NoteFrontmatter {
    fn from(value: models::NoteFrontmatter) -> Self {
        Self {
            book_id: value.book_id,
            chapter_key: value.chapter_key,
            chapter_index: value.chapter_index as u32,
            chapter_title: value.chapter_title,
            chapter_href: value.chapter_href,
            epub_cfi: value.epub_cfi,
            kind: value.kind,
            word_count: value.word_count as u32,
            created_at: value.created_at.map(rfc3339),
            updated_at: value.updated_at.map(rfc3339),
        }
    }
}

impl From<models::ChapterNote> for ChapterNote {
    fn from(value: models::ChapterNote) -> Self {
        Self {
            frontmatter: value.frontmatter.into(),
            body: value.body,
            path: value.path,
        }
    }
}

impl From<models::NoteSearchHit> for NoteSearchHit {
    fn from(value: models::NoteSearchHit) -> Self {
        Self {
            book_id: value.book_id,
            book_title: value.book_title,
            book_author: value.book_author,
            chapter_key: value.chapter_key,
            chapter_index: value.chapter_index as u32,
            chapter_title: value.chapter_title,
            snippet: value.snippet,
            word_count: value.word_count as u32,
            kind: match value.kind {
                models::SearchHitKind::NoteContent => SearchHitKind::NoteContent,
                models::SearchHitKind::ChapterTitle => SearchHitKind::ChapterTitle,
                models::SearchHitKind::BookTarget => SearchHitKind::BookTarget,
            },
            score: value.score,
            snippet_ranges: value
                .snippet_ranges
                .into_iter()
                .map(|r| MatchRange {
                    start: r.start as u32,
                    end: r.end as u32,
                })
                .collect(),
            title_ranges: value
                .title_ranges
                .into_iter()
                .map(|r| MatchRange {
                    start: r.start as u32,
                    end: r.end as u32,
                })
                .collect(),
        }
    }
}

impl From<models::NotesIndexEntry> for NoteIndexEntry {
    fn from(value: models::NotesIndexEntry) -> Self {
        Self {
            chapter_key: value.chapter_key,
            chapter_index: value.chapter_index as u32,
            chapter_title: value.chapter_title,
            word_count: value.word_count as u32,
            updated_at: value.updated_at.map(rfc3339),
        }
    }
}

/// Toggles for markdown rendering; mirrors the core's `ExportOptions`.
#[derive(uniffi::Record)]
pub struct ExportOptions {
    pub include_toc: bool,
    pub include_stats: bool,
    pub include_empty_chapters: bool,
    pub demote_headings: bool,
}

impl From<ExportOptions> for models::ExportOptions {
    fn from(value: ExportOptions) -> Self {
        Self {
            include_toc: value.include_toc,
            include_stats: value.include_stats,
            include_empty_chapters: value.include_empty_chapters,
            demote_headings: value.demote_headings,
        }
    }
}

/// One chapter section of a compiled notes page; note-less chapters carry
/// an empty body and live in `CompiledNotes.empty_chapters`.
#[derive(uniffi::Record)]
pub struct CompiledChapter {
    pub chapter_key: String,
    pub chapter_index: u32,
    pub chapter_title: String,
    /// Markdown, without frontmatter.
    pub body: String,
    pub word_count: u32,
    pub updated_at: Option<String>,
}

impl From<models::CompiledChapter> for CompiledChapter {
    fn from(value: models::CompiledChapter) -> Self {
        Self {
            chapter_key: value.chapter_key,
            chapter_index: value.chapter_index as u32,
            chapter_title: value.chapter_title,
            body: value.body,
            word_count: value.word_count as u32,
            updated_at: value.updated_at.map(rfc3339),
        }
    }
}

/// Every chapter note of a book, compiled into one ordered document.
#[derive(uniffi::Record)]
pub struct CompiledNotes {
    pub book_id: String,
    pub book_title: String,
    pub book_author: String,
    /// Chapters with notes, sorted by chapter index.
    pub chapters: Vec<CompiledChapter>,
    /// Spine chapters without a note file, sorted by chapter index.
    pub empty_chapters: Vec<CompiledChapter>,
    pub chapters_with_notes: u32,
    /// Total chapters in the book's spine.
    pub chapter_count: u32,
    pub total_words: u32,
    pub first_created_at: Option<String>,
    pub last_updated_at: Option<String>,
    /// Shared default export name: `"{author} — {title} — notes.md"`.
    pub suggested_filename: String,
}

impl From<models::CompiledNotes> for CompiledNotes {
    fn from(value: models::CompiledNotes) -> Self {
        Self {
            book_id: value.book_id,
            book_title: value.book_title,
            book_author: value.book_author,
            chapters: value.chapters.into_iter().map(Into::into).collect(),
            empty_chapters: value.empty_chapters.into_iter().map(Into::into).collect(),
            chapters_with_notes: value.chapters_with_notes as u32,
            chapter_count: value.chapter_count as u32,
            total_words: value.total_words as u32,
            first_created_at: value.first_created_at.map(rfc3339),
            last_updated_at: value.last_updated_at.map(rfc3339),
            suggested_filename: value.suggested_filename,
        }
    }
}
