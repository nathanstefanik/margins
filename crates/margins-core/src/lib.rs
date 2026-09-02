pub mod config;
pub mod epub_meta;
pub mod library;
pub mod models;
pub mod notes;
pub mod search;
pub mod sync;

#[cfg(test)]
mod test_fixtures;

pub use config::AppConfig;
pub use library::Library;
pub use models::{
    BookMeta, BookSummary, ChapterNote, ChapterRef, MatchRange, NoteFrontmatter, NoteSearchHit,
    SearchHitKind, SyncReport,
};
