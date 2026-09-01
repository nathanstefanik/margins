use crate::epub_meta;
use crate::models::{BookMeta, BookSummary, LibraryIndex, NoteSearchHit};
use crate::notes;
use chrono::Utc;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum LibraryError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("epub error: {0}")]
    Epub(#[from] epub_meta::EpubError),
    #[error("notes error: {0}")]
    Notes(#[from] notes::NotesError),
    #[error("{0}")]
    Other(String),
}

pub struct Library {
    root: PathBuf,
}

impl Library {
    pub fn open(root: PathBuf) -> Result<Self, LibraryError> {
        fs::create_dir_all(&root)?;
        fs::create_dir_all(root.join("books"))?;
        Ok(Self { root })
    }

    pub fn set_root(&mut self, root: PathBuf) -> Result<(), LibraryError> {
        fs::create_dir_all(&root)?;
        fs::create_dir_all(root.join("books"))?;
        self.root = root;
        Ok(())
    }

    pub fn book_dir(&self, book_id: &str) -> PathBuf {
        self.root.join("books").join(book_id)
    }

    pub fn list_books(&self) -> Result<Vec<BookSummary>, LibraryError> {
        let books_dir = self.root.join("books");
        let mut summaries = Vec::new();

        if !books_dir.exists() {
            return Ok(summaries);
        }

        for entry in fs::read_dir(&books_dir)? {
            let entry = entry?;
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let meta_path = entry.path().join("meta.json");
            if !meta_path.exists() {
                continue;
            }
            let meta: BookMeta = serde_json::from_str(&fs::read_to_string(meta_path)?)?;
            let notes_count = notes::count_notes(&entry.path())?;
            summaries.push(BookSummary {
                id: meta.id,
                title: meta.title,
                author: meta.author,
                added_at: meta.added_at,
                chapter_count: meta.chapters.len(),
                notes_count,
            });
        }

        summaries.sort_by_key(|summary| std::cmp::Reverse(summary.added_at));
        self.write_index(&summaries)?;
        Ok(summaries)
    }

    pub fn get_book(&self, book_id: &str) -> Result<BookMeta, LibraryError> {
        let meta_path = self.book_dir(book_id).join("meta.json");
        if !meta_path.exists() {
            return Err(LibraryError::Other(format!("book not found: {book_id}")));
        }
        Ok(serde_json::from_str(&fs::read_to_string(meta_path)?)?)
    }

    pub fn read_epub_bytes(&self, book_id: &str) -> Result<Vec<u8>, LibraryError> {
        let epub_path = self.book_dir(book_id).join("source.epub");
        if !epub_path.exists() {
            return Err(LibraryError::Other(format!(
                "epub missing for book: {book_id}"
            )));
        }
        Ok(fs::read(epub_path)?)
    }

    pub fn import_epub_with_progress<F>(
        &self,
        source_path: PathBuf,
        mut on_progress: F,
    ) -> Result<BookMeta, LibraryError>
    where
        F: FnMut(u8, &'static str),
    {
        on_progress(0, "preparing");
        if !source_path.exists() {
            return Err(LibraryError::Other("source file does not exist".into()));
        }

        on_progress(5, "reading-metadata");
        let info = epub_meta::parse_epub(&source_path)?;
        on_progress(30, "hashing");
        let book_id = hash_file_with_progress(&source_path, |processed, total| {
            on_progress(progress_between(30, 50, processed, total), "hashing");
        })?;
        let final_book_dir = self.book_dir(&book_id);

        if final_book_dir.join("meta.json").is_file()
            && final_book_dir.join("source.epub").is_file()
        {
            let existing = self.get_book(&book_id)?;
            on_progress(100, "already-imported");
            return Ok(existing);
        }

        let staging = ImportStaging::new(
            self.root
                .join("books")
                .join(format!(".{book_id}.importing-{}", Uuid::new_v4())),
        );

        on_progress(55, "copying");
        fs::create_dir_all(staging.path.join("notes/chapters"))?;

        let source_filename = source_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("book.epub")
            .to_string();

        copy_file_with_progress(
            &source_path,
            &staging.path.join("source.epub"),
            |processed, total| {
                on_progress(progress_between(55, 94, processed, total), "copying");
            },
        )?;

        let meta = BookMeta {
            id: book_id.clone(),
            title: info.title,
            author: info.author,
            language: info.language,
            added_at: Utc::now(),
            source_filename,
            chapters: info.chapters,
        };

        on_progress(95, "saving");
        let meta_raw = serde_json::to_string_pretty(&meta)?;
        fs::write(staging.path.join("meta.json"), meta_raw)?;

        on_progress(97, "saving");
        notes::write_empty_index(&staging.path)?;
        on_progress(99, "saving");
        self.write_book_readme(&staging.path, &meta)?;

        if final_book_dir.exists() {
            // A previous interrupted import can leave an incomplete final directory.
            // Remove it only after the source has been copied into staging.
            fs::remove_dir_all(&final_book_dir)?;
        }
        staging.commit(&final_book_dir)?;
        on_progress(100, "complete");
        Ok(meta)
    }

    pub fn remove_book(&self, book_id: &str) -> Result<(), LibraryError> {
        let book_dir = self.book_dir(book_id);
        if book_dir.exists() {
            fs::remove_dir_all(book_dir)?;
        }
        Ok(())
    }

    pub fn search_notes(&self, query: &str) -> Result<Vec<NoteSearchHit>, LibraryError> {
        Ok(notes::search_notes(&self.root, query)?)
    }

    fn write_index(&self, summaries: &[BookSummary]) -> Result<(), LibraryError> {
        let index = LibraryIndex {
            books: summaries.to_vec(),
        };
        let raw = serde_json::to_string_pretty(&index)?;
        fs::write(self.root.join("index.json"), raw)?;
        Ok(())
    }

    fn write_book_readme(&self, book_dir: &Path, meta: &BookMeta) -> Result<(), LibraryError> {
        let readme = format!(
            "# {}\n\n\
             Author: {}\n\
             Book ID: `{}`\n\n\
             ## Notes layout\n\n\
             Chapter summaries and annotations live in `notes/chapters/` as Markdown files \
             with YAML frontmatter. Each file is self-contained and agent-friendly.\n\n\
             - `meta.json` — book metadata and chapter spine\n\
             - `notes/_index.json` — machine-readable note index\n\
             - `notes/chapters/*.md` — one file per chapter note\n\
             - `source.epub` — imported EPUB copy\n",
            meta.title, meta.author, meta.id
        );
        fs::write(book_dir.join("README.md"), readme)?;
        Ok(())
    }
}

struct ImportStaging {
    path: PathBuf,
    committed: bool,
}

impl ImportStaging {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            committed: false,
        }
    }

    fn commit(mut self, destination: &Path) -> Result<(), std::io::Error> {
        fs::rename(&self.path, destination)?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for ImportStaging {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn hash_file_with_progress<F>(path: &Path, mut on_progress: F) -> Result<String, LibraryError>
where
    F: FnMut(u64, u64),
{
    let mut file = fs::File::open(path)?;
    let total = file.metadata()?.len();
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    let mut processed = 0;
    on_progress(processed, total);
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        processed += read as u64;
        on_progress(processed, total);
    }
    Ok(hex::encode(&hasher.finalize()[..12]))
}

fn copy_file_with_progress<F>(
    source: &Path,
    destination: &Path,
    mut on_progress: F,
) -> Result<(), std::io::Error>
where
    F: FnMut(u64, u64),
{
    let mut source_file = fs::File::open(source)?;
    let total = source_file.metadata()?.len();
    let mut destination_file = fs::File::create(destination)?;
    let mut buffer = [0u8; 64 * 1024];
    let mut processed = 0;
    on_progress(processed, total);

    loop {
        let read = source_file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        destination_file.write_all(&buffer[..read])?;
        processed += read as u64;
        on_progress(processed, total);
    }

    destination_file.flush()?;
    Ok(())
}

fn progress_between(start: u8, end: u8, processed: u64, total: u64) -> u8 {
    if total == 0 {
        return end;
    }

    let range = u128::from(end.saturating_sub(start));
    let completed = u128::from(processed.min(total));
    let total = u128::from(total);
    start.saturating_add((range * completed / total) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_fixtures::write_sample_epub;

    #[test]
    fn import_list_get_remove_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");

        let meta = library
            .import_epub_with_progress(epub.clone(), |_, _| {})
            .unwrap();
        assert_eq!(meta.title, "Sample Book");
        assert_eq!(meta.chapters.len(), 2);
        assert!(library.book_dir(&meta.id).join("source.epub").exists());
        assert!(library
            .book_dir(&meta.id)
            .join("notes/_index.json")
            .exists());

        let again = library.import_epub_with_progress(epub, |_, _| {}).unwrap();
        assert_eq!(again.id, meta.id);

        let listed = library.list_books().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, meta.id);
        assert_eq!(listed[0].notes_count, 0);
        assert!(tmp.path().join("library/index.json").exists());

        let bytes = library.read_epub_bytes(&meta.id).unwrap();
        assert!(!bytes.is_empty());

        library.remove_book(&meta.id).unwrap();
        assert!(library.list_books().unwrap().is_empty());
        assert!(!library.book_dir(&meta.id).exists());
    }

    #[test]
    fn import_reports_monotonic_progress() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let mut updates = Vec::new();

        library
            .import_epub_with_progress(epub, |percent, stage| updates.push((percent, stage)))
            .unwrap();

        assert_eq!(updates.first(), Some(&(0, "preparing")));
        assert_eq!(updates.last(), Some(&(100, "complete")));
        assert!(updates.iter().any(|(_, stage)| *stage == "hashing"));
        assert!(updates.iter().any(|(_, stage)| *stage == "copying"));
        assert!(updates.windows(2).all(|pair| pair[1].0 >= pair[0].0));
    }

    #[test]
    fn failed_import_can_be_retried_without_a_partial_book() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let original = fs::read(&epub).unwrap();
        let mut failed_once = false;

        let first_attempt = library.import_epub_with_progress(epub.clone(), |_, stage| {
            if stage == "copying" && !failed_once {
                failed_once = true;
                fs::remove_file(&epub).unwrap();
            }
        });

        assert!(first_attempt.is_err());
        fs::write(&epub, original).unwrap();
        assert!(library.import_epub_with_progress(epub, |_, _| {}).is_ok());
    }

    #[test]
    fn repairing_incomplete_book_does_not_delete_its_source() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let original_epub = write_sample_epub(tmp.path(), "sample.epub");
        let book_id = hash_file_with_progress(&original_epub, |_, _| {}).unwrap();
        let partial_dir = library.book_dir(&book_id);
        fs::create_dir_all(&partial_dir).unwrap();
        fs::copy(&original_epub, partial_dir.join("source.epub")).unwrap();

        assert!(library
            .import_epub_with_progress(partial_dir.join("source.epub"), |_, _| {})
            .is_ok());
    }

    #[test]
    fn list_books_ignores_interrupted_import_staging_directories() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();
        let staging_dir = library
            .book_dir(&meta.id)
            .parent()
            .unwrap()
            .join(format!(".{}.importing-crashed", meta.id));
        fs::create_dir_all(&staging_dir).unwrap();
        fs::copy(
            library.book_dir(&meta.id).join("meta.json"),
            staging_dir.join("meta.json"),
        )
        .unwrap();

        let listed = library.list_books().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, meta.id);
    }

    #[test]
    fn failed_duplicate_import_does_not_report_completion() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let meta = library
            .import_epub_with_progress(epub.clone(), |_, _| {})
            .unwrap();
        fs::write(library.book_dir(&meta.id).join("meta.json"), b"not json").unwrap();
        let mut updates = Vec::new();

        assert!(library
            .import_epub_with_progress(epub, |percent, stage| updates.push((percent, stage)))
            .is_err());
        assert!(!updates.iter().any(|(percent, _)| *percent == 100));
    }

    #[test]
    fn reimport_repairs_a_missing_source_file() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let meta = library
            .import_epub_with_progress(epub.clone(), |_, _| {})
            .unwrap();
        fs::remove_file(library.book_dir(&meta.id).join("source.epub")).unwrap();

        library.import_epub_with_progress(epub, |_, _| {}).unwrap();
        assert!(library.book_dir(&meta.id).join("source.epub").is_file());
    }

    #[test]
    fn set_root_switches_active_library() {
        let tmp = tempfile::tempdir().unwrap();
        let root_a = tmp.path().join("a");
        let root_b = tmp.path().join("b");
        let epub = write_sample_epub(tmp.path(), "sample.epub");

        let mut library = Library::open(root_a).unwrap();
        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();
        assert_eq!(library.list_books().unwrap().len(), 1);

        library.set_root(root_b).unwrap();
        assert!(library.list_books().unwrap().is_empty());
        assert!(!library.book_dir(&meta.id).exists());
    }
}
