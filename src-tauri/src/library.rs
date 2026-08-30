use crate::epub_meta;
use crate::models::{BookMeta, BookSummary, LibraryIndex};
use crate::notes;
use chrono::Utc;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use thiserror::Error;

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

    pub fn reload(&mut self) -> Result<(), LibraryError> {
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

        summaries.sort_by(|a, b| b.added_at.cmp(&a.added_at));
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

    pub fn import_epub(&self, source_path: PathBuf) -> Result<BookMeta, LibraryError> {
        if !source_path.exists() {
            return Err(LibraryError::Other("source file does not exist".into()));
        }

        let info = epub_meta::parse_epub(&source_path)?;
        let book_id = hash_file(&source_path)?;
        let book_dir = self.book_dir(&book_id);

        if book_dir.exists() {
            return self.get_book(&book_id);
        }

        fs::create_dir_all(book_dir.join("notes/chapters"))?;

        let source_filename = source_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("book.epub")
            .to_string();

        fs::copy(&source_path, book_dir.join("source.epub"))?;

        let meta = BookMeta {
            id: book_id.clone(),
            title: info.title,
            author: info.author,
            language: info.language,
            added_at: Utc::now(),
            source_filename,
            chapters: info.chapters,
        };

        let meta_raw = serde_json::to_string_pretty(&meta)?;
        fs::write(book_dir.join("meta.json"), meta_raw)?;

        notes::write_empty_index(&book_dir)?;
        self.write_book_readme(&book_dir, &meta)?;

        Ok(meta)
    }

    pub fn remove_book(&self, book_id: &str) -> Result<(), LibraryError> {
        let book_dir = self.book_dir(book_id);
        if book_dir.exists() {
            fs::remove_dir_all(book_dir)?;
        }
        Ok(())
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

fn hash_file(path: &Path) -> Result<String, LibraryError> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(&hasher.finalize()[..12]))
}
