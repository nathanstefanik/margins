use chrono::{DateTime, Utc};
use margins_core::models;

#[derive(uniffi::Record)]
pub struct BookSummary {
    pub id: String,
    pub title: String,
    pub author: String,
    pub added_at: String,
    pub chapter_count: u32,
    pub notes_count: u32,
}

#[derive(uniffi::Record)]
pub struct ChapterMeta {
    pub key: String,
    pub index: u32,
    pub title: String,
    pub href: String,
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

#[derive(uniffi::Record)]
pub struct NoteSearchHit {
    pub book_id: String,
    pub book_title: String,
    pub book_author: String,
    pub chapter_key: String,
    pub chapter_index: u32,
    pub chapter_title: String,
    pub snippet: String,
    pub word_count: u32,
}

fn rfc3339(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339()
}

impl From<models::BookSummary> for BookSummary {
    fn from(value: models::BookSummary) -> Self {
        Self {
            id: value.id,
            title: value.title,
            author: value.author,
            added_at: rfc3339(value.added_at),
            chapter_count: value.chapter_count as u32,
            notes_count: value.notes_count as u32,
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
        }
    }
}

impl From<models::BookMeta> for BookMeta {
    fn from(value: models::BookMeta) -> Self {
        Self {
            id: value.id,
            title: value.title,
            author: value.author,
            language: value.language,
            added_at: rfc3339(value.added_at),
            source_filename: value.source_filename,
            chapters: value.chapters.into_iter().map(Into::into).collect(),
        }
    }
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
        }
    }
}
