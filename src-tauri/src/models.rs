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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterMeta {
    pub key: String,
    pub index: usize,
    pub title: String,
    pub href: String,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterNote {
    pub frontmatter: NoteFrontmatter,
    pub body: String,
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
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncReport {
    pub files_copied: usize,
    pub bytes_copied: u64,
    pub destination: String,
}
