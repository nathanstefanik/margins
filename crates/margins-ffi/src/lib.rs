uniffi::setup_scaffolding!();

mod types;

use margins_core::config::AppConfig;
use margins_core::library::Library;
use margins_core::models::NoteFrontmatter;
use margins_core::notes;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use types::{BookMeta, BookSummary, ChapterNote, ChapterRef, NoteSearchHit};

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    #[error("{0}")]
    Message(String),
}

impl From<margins_core::config::ConfigError> for CoreError {
    fn from(error: margins_core::config::ConfigError) -> Self {
        Self::Message(error.to_string())
    }
}

impl From<margins_core::library::LibraryError> for CoreError {
    fn from(error: margins_core::library::LibraryError) -> Self {
        Self::Message(error.to_string())
    }
}

impl From<margins_core::notes::NotesError> for CoreError {
    fn from(error: margins_core::notes::NotesError) -> Self {
        Self::Message(error.to_string())
    }
}

fn poisoned(error: impl std::fmt::Display) -> CoreError {
    CoreError::Message(error.to_string())
}

#[derive(uniffi::Object)]
pub struct MarginsCore {
    config: Mutex<AppConfig>,
    library: Mutex<Library>,
}

#[uniffi::export]
impl MarginsCore {
    #[uniffi::constructor]
    pub fn new(data_dir: Option<String>) -> Result<Arc<Self>, CoreError> {
        let config = AppConfig::load_with_data_dir(data_dir.map(PathBuf::from))?;
        let library = Library::open(config.library_root())?;
        Ok(Arc::new(Self {
            config: Mutex::new(config),
            library: Mutex::new(library),
        }))
    }

    pub fn data_dir(&self) -> Result<String, CoreError> {
        Ok(self
            .config
            .lock()
            .map_err(poisoned)?
            .data_dir()
            .display()
            .to_string())
    }

    pub fn library_root(&self) -> Result<String, CoreError> {
        Ok(self
            .library
            .lock()
            .map_err(poisoned)?
            .root()
            .display()
            .to_string())
    }

    pub fn set_library_root(&self, path: String) -> Result<String, CoreError> {
        let new_root = PathBuf::from(&path);
        let previous_root = self.library.lock().map_err(poisoned)?.root().to_path_buf();

        self.library
            .lock()
            .map_err(poisoned)?
            .set_root(new_root.clone())?;

        let config_result = match self.config.lock() {
            Ok(mut config) => config
                .set_library_root(new_root.clone())
                .map_err(CoreError::from),
            Err(error) => Err(poisoned(error)),
        };

        if let Err(error) = config_result {
            let restore_result = match self.library.lock() {
                Ok(mut library) => library.set_root(previous_root).map_err(CoreError::from),
                Err(restore_error) => Err(poisoned(restore_error)),
            };
            if let Err(restore_error) = restore_result {
                return Err(CoreError::Message(format!(
                    "could not save library directory: {error}; could not restore active directory: {restore_error}"
                )));
            }
            return Err(error);
        }

        Ok(new_root.display().to_string())
    }

    pub fn list_books(&self) -> Result<Vec<BookSummary>, CoreError> {
        let library = self.library.lock().map_err(poisoned)?;
        Ok(library
            .list_books()?
            .into_iter()
            .map(|summary| BookSummary::from_core(summary, &library))
            .collect())
    }

    pub fn import_epub(&self, path: String) -> Result<BookMeta, CoreError> {
        let library = self.library.lock().map_err(poisoned)?;
        Ok(BookMeta::from_core(
            library.import_epub_with_progress(PathBuf::from(path), |_, _| {})?,
            &library,
        ))
    }

    pub fn get_book(&self, id: String) -> Result<BookMeta, CoreError> {
        let library = self.library.lock().map_err(poisoned)?;
        Ok(BookMeta::from_core(library.get_book(&id)?, &library))
    }

    pub fn remove_book(&self, id: String) -> Result<(), CoreError> {
        Ok(self.library.lock().map_err(poisoned)?.remove_book(&id)?)
    }

    pub fn read_epub_bytes(&self, id: String) -> Result<Vec<u8>, CoreError> {
        Ok(self
            .library
            .lock()
            .map_err(poisoned)?
            .read_epub_bytes(&id)?)
    }

    pub fn get_chapter_note(
        &self,
        book_id: String,
        chapter_key: String,
    ) -> Result<ChapterNote, CoreError> {
        let library = self.library.lock().map_err(poisoned)?;
        Ok(notes::load_chapter_note(&library.book_dir(&book_id), &chapter_key)?.into())
    }

    pub fn save_chapter_note(
        &self,
        book_id: String,
        chapter: ChapterRef,
        body: String,
        kind: Option<String>,
    ) -> Result<ChapterNote, CoreError> {
        let library = self.library.lock().map_err(poisoned)?;
        let book_dir = library.book_dir(&book_id);
        let meta = library.get_book(&book_id)?;
        let chapter_meta = meta
            .chapters
            .iter()
            .find(|c| c.key == chapter.key)
            .cloned()
            .ok_or_else(|| CoreError::Message(format!("unknown chapter key: {}", chapter.key)))?;

        let frontmatter = NoteFrontmatter {
            book_id: book_id.clone(),
            chapter_key: chapter_meta.key.clone(),
            chapter_index: chapter_meta.index,
            chapter_title: chapter_meta.title.clone(),
            chapter_href: chapter_meta.href.clone(),
            epub_cfi: chapter.epub_cfi,
            kind: kind.unwrap_or_else(|| "summary".into()),
            word_count: notes::count_words(&body),
            created_at: None,
            updated_at: None,
        };

        Ok(notes::save_chapter_note(&book_dir, &chapter_meta, frontmatter, &body)?.into())
    }

    pub fn search_notes(&self, query: String) -> Result<Vec<NoteSearchHit>, CoreError> {
        Ok(self
            .library
            .lock()
            .map_err(poisoned)?
            .search_notes(&query)?
            .into_iter()
            .map(Into::into)
            .collect())
    }
}
