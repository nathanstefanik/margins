pub mod compile;
pub mod config;
pub mod epub_meta;
pub mod library;
pub mod models;
pub mod notes;
pub mod search;
pub mod sync;

#[cfg(test)]
mod test_fixtures;

pub use compile::{compile_book_notes, render_markdown, suggested_export_filename};
pub use config::AppConfig;
pub use library::Library;
pub use models::{
    BookMeta, BookSummary, ChapterNote, ChapterRef, CompiledChapter, CompiledNotes, ExportOptions,
    MatchRange, NoteFrontmatter, NoteSearchHit, SearchHitKind, SyncReport,
};
