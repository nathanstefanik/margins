use crate::epub_meta;
use crate::models::{BookMeta, BookSummary, LibraryIndex, NoteSearchHit, ReadingPosition};
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

    pub fn root(&self) -> &Path {
        &self.root
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
            let cover = meta
                .cover
                .clone()
                .or_else(|| self.backfill_cover(&entry.path(), &meta));
            let progress_percent = self.read_position(&meta.id).map(|p| p.percent);
            summaries.push(BookSummary {
                id: meta.id,
                title: meta.title,
                author: meta.author,
                added_at: meta.added_at,
                chapter_count: meta.chapters.len(),
                notes_count,
                cover,
                progress_percent,
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
        let mut meta: BookMeta = serde_json::from_str(&fs::read_to_string(meta_path)?)?;
        meta.progress_percent = self.read_position(book_id).map(|p| p.percent);
        Ok(meta)
    }

    /// The book's saved reading position, or `None` when it was never
    /// opened or the position file is missing/corrupt (a corrupt file must
    /// not break the library — the reader falls back to chapter 1).
    pub fn read_position(&self, book_id: &str) -> Option<ReadingPosition> {
        let path = self.book_dir(book_id).join("position.json");
        let raw = fs::read_to_string(path).ok()?;
        serde_json::from_str(&raw).ok()
    }

    /// Saves the book's reading position. Percent is clamped to 0–100.
    pub fn write_position(
        &self,
        book_id: &str,
        mut position: ReadingPosition,
    ) -> Result<(), LibraryError> {
        let book_dir = self.book_dir(book_id);
        if !book_dir.is_dir() {
            return Err(LibraryError::Other(format!("book not found: {book_id}")));
        }
        position.percent = position.percent.clamp(0.0, 100.0);
        position.updated_at = Utc::now();
        let raw = serde_json::to_string_pretty(&position)?;
        fs::write(book_dir.join("position.json"), raw)?;
        Ok(())
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

        let epub_meta::EpubInfo {
            title,
            author,
            language,
            chapters,
            cover,
        } = info;

        let mut cover_name = cover
            .as_ref()
            .map(|cover| format!("cover.{}", cover.extension));
        if let (Some(cover), Some(name)) = (&cover, &cover_name) {
            // A cover is a nice-to-have: a failed write must not fail the
            // import, so the meta records the name only on success.
            if fs::write(staging.path.join(name), &cover.bytes).is_err() {
                cover_name = None;
            }
        }

        let meta = BookMeta {
            id: book_id.clone(),
            title,
            author,
            language,
            added_at: Utc::now(),
            source_filename,
            chapters,
            cover: cover_name,
            progress_percent: None,
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

    /// One-shot cover backfill for books imported before covers were
    /// extracted: pulls the cover out of the retained `source.epub`, writes
    /// it into the book directory, and records the file name in `meta.json`.
    /// Books whose EPUB has no cover are re-probed on each scan (a cheap zip
    /// central-directory read at personal-library scale).
    fn backfill_cover(&self, book_dir: &Path, meta: &BookMeta) -> Option<String> {
        let source = book_dir.join("source.epub");
        if !source.is_file() {
            return None;
        }
        let cover = epub_meta::extract_cover_from_epub(&source)?;
        let name = format!("cover.{}", cover.extension);
        fs::write(book_dir.join(&name), &cover.bytes).ok()?;
        let mut updated = meta.clone();
        updated.cover = Some(name.clone());
        if let Ok(raw) = serde_json::to_string_pretty(&updated) {
            let _ = fs::write(book_dir.join("meta.json"), raw);
        }
        Some(name)
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
    use crate::test_fixtures::{
        write_sample_epub, write_sample_epub_covered, SampleCover, SAMPLE_COVER_PNG,
    };

    #[test]
    fn import_stores_cover_and_reports_it_in_the_catalog() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub_covered(tmp.path(), "covered.epub", SampleCover::Epub3);

        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();
        assert_eq!(meta.cover.as_deref(), Some("cover.png"));

        let cover_path = library.book_dir(&meta.id).join("cover.png");
        assert_eq!(fs::read(&cover_path).unwrap(), SAMPLE_COVER_PNG);

        let listed = library.list_books().unwrap();
        assert_eq!(listed[0].cover.as_deref(), Some("cover.png"));

        let index = fs::read_to_string(tmp.path().join("library/index.json")).unwrap();
        assert!(
            index.contains("\"cover\": \"cover.png\"") || index.contains("\"cover\":\"cover.png\"")
        );

        let fetched = library.get_book(&meta.id).unwrap();
        assert_eq!(fetched.cover.as_deref(), Some("cover.png"));
    }

    #[test]
    fn import_without_cover_succeeds_with_null_cover() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "plain.epub");

        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();
        assert!(meta.cover.is_none());
        assert!(library.list_books().unwrap()[0].cover.is_none());
    }

    #[test]
    fn scan_backfills_covers_for_legacy_books() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub_covered(tmp.path(), "legacy.epub", SampleCover::Epub3);
        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();

        // Simulate a book imported before cover extraction existed.
        let book_dir = library.book_dir(&meta.id);
        let mut meta_json: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(book_dir.join("meta.json")).unwrap()).unwrap();
        meta_json.as_object_mut().unwrap().remove("cover");
        fs::write(
            book_dir.join("meta.json"),
            serde_json::to_string_pretty(&meta_json).unwrap(),
        )
        .unwrap();
        fs::remove_file(book_dir.join("cover.png")).unwrap();

        // The next scan extracts the cover again and persists it.
        let listed = library.list_books().unwrap();
        assert_eq!(listed[0].cover.as_deref(), Some("cover.png"));
        assert_eq!(
            fs::read(book_dir.join("cover.png")).unwrap(),
            SAMPLE_COVER_PNG
        );
        let stored: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(book_dir.join("meta.json")).unwrap()).unwrap();
        assert_eq!(stored["cover"], "cover.png");

        // ... and a follow-up scan does not duplicate or drop it.
        let listed_again = library.list_books().unwrap();
        assert_eq!(listed_again[0].cover.as_deref(), Some("cover.png"));
    }

    #[test]
    fn scan_tolerates_a_corrupt_source_when_backfilling() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "plain.epub");
        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();

        // Corrupt the source: the scan must still list the book, coverless.
        fs::write(library.book_dir(&meta.id).join("source.epub"), b"junk").unwrap();
        let listed = library.list_books().unwrap();
        assert_eq!(listed.len(), 1);
        assert!(listed[0].cover.is_none());
    }

    #[test]
    fn reading_position_round_trips_and_clamps_percent() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();

        // Never opened: no position.
        assert!(library.read_position(&meta.id).is_none());

        let position = ReadingPosition {
            chapter_key: "002".into(),
            epub_cfi: Some("epubcfi(/6/4!/4/2)".into()),
            percent: 42.5,
            updated_at: Utc::now(),
        };
        library.write_position(&meta.id, position).unwrap();

        let read = library.read_position(&meta.id).unwrap();
        assert_eq!(read.chapter_key, "002");
        assert_eq!(read.epub_cfi.as_deref(), Some("epubcfi(/6/4!/4/2)"));
        assert!((read.percent - 42.5).abs() < f64::EPSILON);

        // Percent clamps to 0–100.
        library
            .write_position(
                &meta.id,
                ReadingPosition {
                    chapter_key: "002".into(),
                    epub_cfi: None,
                    percent: 150.0,
                    updated_at: Utc::now(),
                },
            )
            .unwrap();
        assert_eq!(library.read_position(&meta.id).unwrap().percent, 100.0);

        library
            .write_position(
                &meta.id,
                ReadingPosition {
                    chapter_key: "001".into(),
                    epub_cfi: None,
                    percent: -5.0,
                    updated_at: Utc::now(),
                },
            )
            .unwrap();
        assert_eq!(library.read_position(&meta.id).unwrap().percent, 0.0);

        // The catalog and the book detail join the percent through.
        assert_eq!(library.list_books().unwrap()[0].progress_percent, Some(0.0));
        assert_eq!(
            library.get_book(&meta.id).unwrap().progress_percent,
            Some(0.0)
        );
    }

    #[test]
    fn corrupt_position_file_falls_back_to_none() {
        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let meta = library.import_epub_with_progress(epub, |_, _| {}).unwrap();

        fs::write(
            library.book_dir(&meta.id).join("position.json"),
            b"not json",
        )
        .unwrap();
        assert!(library.read_position(&meta.id).is_none());
        assert_eq!(library.list_books().unwrap()[0].progress_percent, None);
        assert_eq!(library.get_book(&meta.id).unwrap().progress_percent, None);
    }

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
