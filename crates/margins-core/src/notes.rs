use crate::marks;
use crate::models::{ChapterMeta, ChapterNote, Mark, NoteFrontmatter, NotesIndex, NotesIndexEntry};
use chrono::Utc;
use regex::Regex;
use std::fs;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum NotesError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("yaml error: {0}")]
    Yaml(#[from] serde_yaml::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("{0}")]
    Other(String),
}

pub fn write_empty_index(book_dir: &Path) -> Result<(), NotesError> {
    let notes_dir = book_dir.join("notes");
    fs::create_dir_all(notes_dir.join("chapters"))?;
    let index = NotesIndex { chapters: vec![] };
    let raw = serde_json::to_string_pretty(&index)?;
    fs::write(notes_dir.join("_index.json"), raw)?;
    Ok(())
}

pub fn count_notes(book_dir: &Path) -> Result<usize, NotesError> {
    let chapters_dir = book_dir.join("notes/chapters");
    if !chapters_dir.exists() {
        return Ok(0);
    }
    Ok(fs::read_dir(chapters_dir)?
        .filter(|e| {
            e.as_ref()
                .map(|e| e.path().extension().is_some_and(|ext| ext == "md"))
                .unwrap_or(false)
        })
        .count())
}

/// Deletes every note file under `notes/chapters/` and resets
/// `notes/_index.json` to empty. Returns how many note files were removed.
/// Everything else about the book (spine, reading position) is untouched.
pub fn clear_book_notes(book_dir: &Path) -> Result<usize, NotesError> {
    let chapters_dir = book_dir.join("notes/chapters");
    let mut removed = 0;
    if chapters_dir.exists() {
        for entry in fs::read_dir(&chapters_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "md") && path.is_file() {
                fs::remove_file(&path)?;
                removed += 1;
            }
        }
    }
    write_empty_index(book_dir)?;
    Ok(removed)
}

/// Reads the book's `notes/_index.json`. A missing or unparsable index is
/// treated as "no notes" so callers never need to special-case it.
pub fn read_notes_index(book_dir: &Path) -> Result<NotesIndex, NotesError> {
    let index_path = book_dir.join("notes/_index.json");
    if !index_path.exists() {
        return Ok(NotesIndex { chapters: vec![] });
    }
    match fs::read_to_string(&index_path) {
        Ok(raw) => Ok(serde_json::from_str(&raw)?),
        Err(err) => Err(NotesError::Io(err)),
    }
}

pub fn load_chapter_note(book_dir: &Path, chapter_key: &str) -> Result<ChapterNote, NotesError> {
    let notes_dir = book_dir.join("notes");
    let index = read_notes_index(book_dir)?;

    if let Some(entry) = index.chapters.iter().find(|c| c.chapter_key == chapter_key) {
        let path = notes_dir.join(&entry.file);
        return parse_note_file(&path, chapter_key);
    }

    let meta_path = book_dir.join("meta.json");
    let meta: crate::models::BookMeta = serde_json::from_str(&fs::read_to_string(meta_path)?)?;
    let chapter = meta
        .chapters
        .iter()
        .find(|c| c.key == chapter_key)
        .ok_or_else(|| NotesError::Other(format!("unknown chapter: {chapter_key}")))?;

    Ok(blank_note(&meta.id, chapter))
}

/// A chapter note that has no file yet: blank body, no marks.
fn blank_note(book_id: &str, chapter: &ChapterMeta) -> ChapterNote {
    ChapterNote {
        frontmatter: NoteFrontmatter {
            book_id: book_id.to_string(),
            chapter_key: chapter.key.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_href: chapter.href.clone(),
            epub_cfi: None,
            kind: "summary".into(),
            word_count: 0,
            created_at: None,
            updated_at: None,
        },
        body: String::new(),
        marks: vec![],
        path: String::new(),
    }
}

/// A parsed note file: frontmatter, long-form body, and the marks section
/// blocks (marks plus any verbatim-preserved raw content).
struct NoteFile {
    frontmatter: NoteFrontmatter,
    body: String,
    items: Vec<marks::MarkItem>,
}

fn parse_note_content(raw: &str, chapter_key: &str) -> Result<NoteFile, NotesError> {
    let (yaml, content) = split_frontmatter(raw)?;
    let mut frontmatter: NoteFrontmatter = serde_yaml::from_str(&yaml)?;
    frontmatter.chapter_key = chapter_key.to_string();
    let (body, section) = marks::split_body(&content);
    let body = body.trim_start_matches('\n').to_string();
    let items = section
        .map(|section| marks::parse_section(&section))
        .unwrap_or_default();
    Ok(NoteFile {
        frontmatter,
        body,
        items,
    })
}

/// Canonical path (relative to the notes dir) for a chapter's note file:
/// the indexed file when present, else the name the note would get.
fn note_relative_path(book_dir: &Path, chapter: &ChapterMeta) -> Result<String, NotesError> {
    let index = read_notes_index(book_dir)?;
    Ok(match index.chapters.iter().find(|e| e.chapter_key == chapter.key) {
        Some(entry) => entry.file.clone(),
        None => format!(
            "chapters/{}-{}.md",
            chapter.key,
            slugify(&chapter.title)
        ),
    })
}

/// Reads and parses the chapter's note file, if it exists.
fn read_note_file(book_dir: &Path, chapter: &ChapterMeta) -> Result<Option<NoteFile>, NotesError> {
    let path = book_dir.join("notes").join(note_relative_path(book_dir, chapter)?);
    if !path.is_file() {
        return Ok(None);
    }
    Ok(Some(parse_note_content(&fs::read_to_string(&path)?, &chapter.key)?))
}

/// Adds or replaces the index entry for `chapter`, keeping the index
/// sorted by chapter index, and writes it back.
fn upsert_index_entry(
    book_dir: &Path,
    chapter: &ChapterMeta,
    file: &str,
    word_count: usize,
    mark_count: usize,
    updated_at: Option<chrono::DateTime<Utc>>,
) -> Result<(), NotesError> {
    let notes_dir = book_dir.join("notes");
    let mut index: NotesIndex = if notes_dir.join("_index.json").exists() {
        serde_json::from_str(&fs::read_to_string(notes_dir.join("_index.json"))?)?
    } else {
        NotesIndex { chapters: vec![] }
    };
    index.chapters.retain(|e| e.chapter_key != chapter.key);
    index.chapters.push(NotesIndexEntry {
        chapter_key: chapter.key.clone(),
        file: file.to_string(),
        chapter_index: chapter.index,
        chapter_title: chapter.title.clone(),
        word_count,
        mark_count,
        updated_at,
    });
    index.chapters.sort_by_key(|e| e.chapter_index);
    let raw = serde_json::to_string_pretty(&index)?;
    fs::write(notes_dir.join("_index.json"), raw)?;
    Ok(())
}

pub fn save_chapter_note(
    book_dir: &Path,
    chapter: &ChapterMeta,
    mut frontmatter: NoteFrontmatter,
    body: &str,
) -> Result<ChapterNote, NotesError> {
    let notes_dir = book_dir.join("notes");
    fs::create_dir_all(notes_dir.join("chapters"))?;

    let slug = slugify(&chapter.title);
    let filename = format!("{}-{}.md", chapter.key, slug);
    let relative_path = format!("chapters/{filename}");
    let path = notes_dir.join(&relative_path);

    // The file name carries the chapter's title slug, so a chapter whose
    // title was re-derived since the note was written (see
    // `library::CHAPTERS_VERSION`) would otherwise leave the old file
    // behind, outside `_index.json` and invisible to every reader. Move it
    // to the new name instead: one file per chapter is the contract.
    let existing_index = read_notes_index(book_dir)?;
    if let Some(previous) = existing_index
        .chapters
        .iter()
        .find(|entry| entry.chapter_key == chapter.key)
        .map(|entry| entry.file.clone())
    {
        let source = notes_dir.join(&previous);
        if previous != relative_path && source.is_file() && !path.exists() {
            let _ = fs::rename(&source, &path);
        }
    }

    // Marks: the incoming body is authoritative for any marks section it
    // carries (a blob frontend saving back what it loaded, possibly with
    // hand edits); if it carries none, the marks already on disk are
    // preserved verbatim. Either way a marks-unaware save cannot destroy
    // them. The file is read from its final path — after the rename above,
    // the index may still point at the old name.
    let existing = if path.is_file() {
        parse_note_content(&fs::read_to_string(&path)?, &chapter.key).ok()
    } else {
        None
    };
    let disk_created_at = existing.as_ref().and_then(|n| n.frontmatter.created_at);
    let (long_body, items) = match marks::split_body(body) {
        (long_body, Some(section)) => (long_body, marks::parse_section(&section)),
        (long_body, None) => {
            let items = existing.map(|note| note.items).unwrap_or_default();
            (long_body, items)
        }
    };

    let now = Utc::now();
    frontmatter.created_at = disk_created_at.or(frontmatter.created_at).or(Some(now));
    frontmatter.updated_at = Some(now);
    frontmatter.word_count = count_words(&long_body);

    let content = render_note(&frontmatter, &long_body, &items)?;
    fs::write(&path, &content)?;

    upsert_index_entry(
        book_dir,
        chapter,
        &relative_path,
        frontmatter.word_count,
        marks::marks(&items).len(),
        frontmatter.updated_at,
    )?;

    Ok(ChapterNote {
        frontmatter,
        body: long_body,
        marks: marks::marks(&items),
        path: path.display().to_string(),
    })
}

/// Appends a mark to the chapter's note file, creating the file (and its
/// index entry) when the chapter has no note yet. The id and timestamp are
/// assigned here; the returned `Mark` is what callers persist.
pub fn append_mark(
    book_dir: &Path,
    chapter: &ChapterMeta,
    cfi: Option<String>,
    percent: Option<f64>,
    quote: &str,
    body: &str,
) -> Result<Mark, NotesError> {
    let existing = read_note_file(book_dir, chapter)?;
    let now = Utc::now();

    let mut frontmatter = match &existing {
        Some(note) => note.frontmatter.clone(),
        None => blank_note(&chapter_dir_book_id(book_dir, chapter)?, chapter).frontmatter,
    };
    if existing.is_none() {
        frontmatter.created_at = Some(now);
    }
    frontmatter.updated_at = Some(now);

    let (items, existing_body, ids) = match existing {
        Some(note) => {
            let ids = marks::marks(&note.items).iter().map(|m| m.id.clone()).collect();
            (note.items, note.body, ids)
        }
        None => (Vec::new(), String::new(), Vec::new()),
    };
    let mut items = items;
    let mut mark = Mark {
        id: marks::new_mark_id(),
        cfi,
        at: now,
        percent,
        quote: quote.to_string(),
        body: body.to_string(),
    };
    while ids.contains(&mark.id) {
        mark.id = marks::new_mark_id();
    }
    marks::append_item(&mut items, mark.clone());
    write_note_file(book_dir, chapter, &frontmatter, &existing_body, &items)?;

    let relative_path = note_relative_path(book_dir, chapter)?;
    upsert_index_entry(
        book_dir,
        chapter,
        &relative_path,
        frontmatter.word_count,
        marks::marks(&items).len(),
        Some(now),
    )?;
    Ok(mark)
}

/// Replaces the mark with `mark.id` (other blocks keep their bytes).
pub fn update_mark(book_dir: &Path, chapter: &ChapterMeta, mark: Mark) -> Result<(), NotesError> {
    let mut note = read_note_file(book_dir, chapter)?
        .ok_or_else(|| NotesError::Other(format!("no note for chapter {}", chapter.key)))?;
    let mut items = std::mem::take(&mut note.items);
    if !marks::update_item(&mut items, mark) {
        return Err(NotesError::Other("mark not found".into()));
    }
    rewrite_note_keeping_body(book_dir, chapter, note, items)
}

/// Removes the mark with `id` (other blocks keep their bytes).
pub fn delete_mark(book_dir: &Path, chapter: &ChapterMeta, id: &str) -> Result<(), NotesError> {
    let mut note = read_note_file(book_dir, chapter)?
        .ok_or_else(|| NotesError::Other(format!("no note for chapter {}", chapter.key)))?;
    let mut items = std::mem::take(&mut note.items);
    if !marks::delete_item(&mut items, id) {
        return Err(NotesError::Other("mark not found".into()));
    }
    rewrite_note_keeping_body(book_dir, chapter, note, items)
}

/// Re-writes a note file after a mark-only mutation: body, word count, and
/// created_at are untouched; updated_at and the index entry move forward.
fn rewrite_note_keeping_body(
    book_dir: &Path,
    chapter: &ChapterMeta,
    note: NoteFile,
    items: Vec<marks::MarkItem>,
) -> Result<(), NotesError> {
    let mut frontmatter = note.frontmatter.clone();
    frontmatter.updated_at = Some(Utc::now());
    write_note_file(book_dir, chapter, &frontmatter, &note.body, &items)?;

    let relative_path = note_relative_path(book_dir, chapter)?;
    upsert_index_entry(
        book_dir,
        chapter,
        &relative_path,
        frontmatter.word_count,
        marks::marks(&items).len(),
        frontmatter.updated_at,
    )?;
    Ok(())
}

fn write_note_file(
    book_dir: &Path,
    chapter: &ChapterMeta,
    frontmatter: &NoteFrontmatter,
    body: &str,
    items: &[marks::MarkItem],
) -> Result<(), NotesError> {
    let notes_dir = book_dir.join("notes");
    fs::create_dir_all(notes_dir.join("chapters"))?;
    let path = notes_dir.join(note_relative_path(book_dir, chapter)?);
    let content = render_note(frontmatter, body, items)?;
    fs::write(&path, &content)?;
    Ok(())
}

/// The book id for blank-note frontmatter; read from `meta.json`, which
/// every book directory carries.
fn chapter_dir_book_id(book_dir: &Path, _chapter: &ChapterMeta) -> Result<String, NotesError> {
    let meta_path = book_dir.join("meta.json");
    let meta: crate::models::BookMeta = serde_json::from_str(&fs::read_to_string(meta_path)?)?;
    Ok(meta.id)
}

pub(crate) fn parse_note_file(path: &Path, chapter_key: &str) -> Result<ChapterNote, NotesError> {
    let raw = fs::read_to_string(path)?;
    let note = parse_note_content(&raw, chapter_key)?;
    Ok(ChapterNote {
        frontmatter: note.frontmatter,
        body: note.body,
        marks: marks::marks(&note.items),
        path: path.display().to_string(),
    })
}

fn split_frontmatter(raw: &str) -> Result<(String, String), NotesError> {
    let re = Regex::new(r"(?s)\A---\n(.*?)\n---\n?(.*)\z").unwrap();
    let caps = re
        .captures(raw)
        .ok_or_else(|| NotesError::Other("note file missing YAML frontmatter".into()))?;
    Ok((caps[1].to_string(), caps[2].to_string()))
}

fn render_note(
    frontmatter: &NoteFrontmatter,
    body: &str,
    items: &[marks::MarkItem],
) -> Result<String, NotesError> {
    let yaml = serde_yaml::to_string(frontmatter)?;
    let mut content = format!("---\n{yaml}---\n\n{body}");
    if !items.is_empty() {
        content.push_str("\n\n");
        content.push_str(&marks::serialize_items(items));
    }
    Ok(content)
}

pub fn count_words(text: &str) -> usize {
    text.split_whitespace()
        .filter(|w| !w.starts_with('#'))
        .count()
}

pub(crate) fn slugify(title: &str) -> String {
    let lower = title.to_lowercase();
    let re = Regex::new(r"[^a-z0-9]+").unwrap();
    let slug = re.replace_all(&lower, "-");
    slug.trim_matches('-').chars().take(48).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::BookMeta;
    use chrono::Utc;

    fn seed_book(dir: &Path) -> ChapterMeta {
        let chapter = ChapterMeta {
            key: "001".into(),
            index: 0,
            title: "Introduction".into(),
            href: "OEBPS/chapter1.xhtml".into(),
            fragment: None,
        };
        let meta = BookMeta {
            id: "abc123".into(),
            title: "Sample Book".into(),
            author: "Test Author".into(),
            language: Some("en".into()),
            added_at: Utc::now(),
            source_filename: "sample.epub".into(),
            chapters: vec![chapter.clone()],
            cover: None,
            progress_percent: None,
            chapters_version: crate::library::CHAPTERS_VERSION,
        };
        fs::create_dir_all(dir.join("notes/chapters")).unwrap();
        fs::write(
            dir.join("meta.json"),
            serde_json::to_string_pretty(&meta).unwrap(),
        )
        .unwrap();
        write_empty_index(dir).unwrap();
        chapter
    }

    #[test]
    fn count_words_skips_markdown_heading_tokens() {
        // "# Heading" tokenizes as "#" + "Heading"; only "#" is dropped.
        assert_eq!(count_words("# Heading\none two"), 3);
        assert_eq!(count_words(""), 0);
    }

    #[test]
    fn slugify_chapter_titles() {
        assert_eq!(slugify("The Market"), "the-market");
        assert_eq!(slugify("  Hello!!! World  "), "hello-world");
    }

    #[test]
    fn save_and_load_note_roundtrip_updates_index() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);

        let body = "This is a chapter summary with about twenty words so we can check persistence of content and word count.";
        let frontmatter = NoteFrontmatter {
            book_id: "abc123".into(),
            chapter_key: chapter.key.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_href: chapter.href.clone(),
            epub_cfi: Some("epubcfi(/6/2)".into()),
            kind: "summary".into(),
            word_count: 0,
            created_at: None,
            updated_at: None,
        };

        let saved = save_chapter_note(book_dir, &chapter, frontmatter, body).unwrap();
        assert!(Path::new(&saved.path).exists());
        assert_eq!(saved.frontmatter.word_count, count_words(body));
        assert!(saved.frontmatter.created_at.is_some());
        assert_eq!(count_notes(book_dir).unwrap(), 1);

        let loaded = load_chapter_note(book_dir, "001").unwrap();
        assert_eq!(loaded.body, body);
        assert_eq!(loaded.frontmatter.kind, "summary");
        assert_eq!(
            loaded.frontmatter.epub_cfi.as_deref(),
            Some("epubcfi(/6/2)")
        );

        let index: NotesIndex =
            serde_json::from_str(&fs::read_to_string(book_dir.join("notes/_index.json")).unwrap())
                .unwrap();
        assert_eq!(index.chapters.len(), 1);
        assert_eq!(index.chapters[0].file, "chapters/001-introduction.md");
    }

    #[test]
    fn a_retitled_chapter_moves_its_note_instead_of_orphaning_it() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);

        let frontmatter = NoteFrontmatter {
            book_id: "abc123".into(),
            chapter_key: chapter.key.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_href: chapter.href.clone(),
            epub_cfi: None,
            kind: "summary".into(),
            word_count: 0,
            created_at: None,
            updated_at: None,
        };
        let first =
            save_chapter_note(book_dir, &chapter, frontmatter.clone(), "first draft").unwrap();
        assert!(first.path.ends_with("001-introduction.md"));

        // The library scan re-derived the title from the book's TOC.
        let retitled = ChapterMeta {
            title: "Opening Remarks".into(),
            ..chapter.clone()
        };
        let second = save_chapter_note(book_dir, &retitled, frontmatter, "second draft").unwrap();

        assert!(second.path.ends_with("001-opening-remarks.md"));
        assert_eq!(first.frontmatter.created_at, second.frontmatter.created_at);
        assert!(!book_dir.join("notes/chapters/001-introduction.md").exists());
        let index = read_notes_index(book_dir).unwrap();
        assert_eq!(index.chapters.len(), 1);
        assert_eq!(index.chapters[0].file, "chapters/001-opening-remarks.md");
        assert_eq!(
            load_chapter_note(book_dir, "001").unwrap().body.trim(),
            "second draft"
        );
    }

    #[test]
    fn resave_preserves_created_at() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);

        let frontmatter = NoteFrontmatter {
            book_id: "abc123".into(),
            chapter_key: chapter.key.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_href: chapter.href.clone(),
            epub_cfi: None,
            kind: "summary".into(),
            word_count: 0,
            created_at: None,
            updated_at: None,
        };

        let first =
            save_chapter_note(book_dir, &chapter, frontmatter.clone(), "first draft").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        let second = save_chapter_note(
            book_dir,
            &chapter,
            frontmatter,
            "second draft with more words",
        )
        .unwrap();

        assert_eq!(first.frontmatter.created_at, second.frontmatter.created_at);
        assert_ne!(first.frontmatter.updated_at, second.frontmatter.updated_at);
        assert_eq!(
            load_chapter_note(book_dir, "001").unwrap().body,
            "second draft with more words"
        );
    }

    #[test]
    fn load_missing_note_returns_blank_body() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        seed_book(book_dir);

        let note = load_chapter_note(book_dir, "001").unwrap();
        assert!(note.body.is_empty());
        assert_eq!(note.frontmatter.word_count, 0);
        assert!(note.path.is_empty());
    }

    #[test]
    fn clear_book_notes_removes_files_and_resets_index() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);

        let frontmatter = NoteFrontmatter {
            book_id: "abc123".into(),
            chapter_key: chapter.key.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_href: chapter.href.clone(),
            epub_cfi: None,
            kind: "summary".into(),
            word_count: 0,
            created_at: None,
            updated_at: None,
        };
        save_chapter_note(book_dir, &chapter, frontmatter, "a note to lose").unwrap();
        assert_eq!(count_notes(book_dir).unwrap(), 1);

        let removed = clear_book_notes(book_dir).unwrap();
        assert_eq!(removed, 1);
        assert_eq!(count_notes(book_dir).unwrap(), 0);

        let index = read_notes_index(book_dir).unwrap();
        assert!(index.chapters.is_empty());

        let note = load_chapter_note(book_dir, "001").unwrap();
        assert!(note.body.is_empty());
        assert!(note.path.is_empty());
    }

    #[test]
    fn clear_book_notes_without_notes_writes_empty_index() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        seed_book(book_dir);

        assert_eq!(clear_book_notes(book_dir).unwrap(), 0);
        assert!(book_dir.join("notes/_index.json").exists());
        let index = read_notes_index(book_dir).unwrap();
        assert!(index.chapters.is_empty());
    }

    // ---- marks integration -------------------------------------------------

    /// Frontmatter block matching `seed_book`'s chapter, for hand-composed
    /// note files.
    fn frontmatter_block(book_dir: &Path, chapter_key: &str) -> String {
        let meta: crate::models::BookMeta = serde_json::from_str(
            &fs::read_to_string(book_dir.join("meta.json")).unwrap(),
        )
        .unwrap();
        let chapter = meta.chapters.iter().find(|c| c.key == chapter_key).unwrap();
        format!(
            "---\nbook_id: {}\nchapter_key: '{}'\nchapter_index: {}\n\
             chapter_title: '{}'\nchapter_href: {}\nepub_cfi: null\n\
             kind: summary\nword_count: 3\n---\n",
            meta.id, chapter.key, chapter.index, chapter.title, chapter.href
        )
    }

    /// Composes a note file with a marks section; returns the exact bytes
    /// of the marks region (sentinel line through end of file).
    fn write_marked_note(book_dir: &Path, chapter_key: &str, body: &str, marks_region: &str) {
        let content = format!(
            "{}\n{}\n{}",
            frontmatter_block(book_dir, chapter_key),
            body,
            marks_region
        );
        let meta: crate::models::BookMeta = serde_json::from_str(
            &fs::read_to_string(book_dir.join("meta.json")).unwrap(),
        )
        .unwrap();
        let chapter = meta.chapters.iter().find(|c| c.key == chapter_key).unwrap();
        let file = format!(
            "chapters/{}-{}.md",
            chapter.key,
            slugify(&chapter.title)
        );
        fs::write(book_dir.join("notes").join(&file), content).unwrap();
        let index_path = book_dir.join("notes/_index.json");
        let mut doc: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&index_path).unwrap()).unwrap();
        doc["chapters"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "chapter_key": chapter_key,
                "file": file,
                "chapter_index": chapter.index,
                "chapter_title": chapter.title,
                "word_count": 3,
                "mark_count": 2,
                "updated_at": chrono::Utc::now().to_rfc3339(),
            }));
        fs::write(&index_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    }

    /// The marks region of a note file: sentinel line through end of file.
    fn marks_region(book_dir: &Path, chapter_key: &str) -> String {
        let meta: crate::models::BookMeta = serde_json::from_str(
            &fs::read_to_string(book_dir.join("meta.json")).unwrap(),
        )
        .unwrap();
        let chapter = meta.chapters.iter().find(|c| c.key == chapter_key).unwrap();
        let file = format!(
            "chapters/{}-{}.md",
            chapter.key,
            slugify(&chapter.title)
        );
        let raw = fs::read_to_string(book_dir.join("notes").join(&file)).unwrap();
        raw[raw.find(marks::SENTINEL).unwrap()..].to_string()
    }

    fn two_mark_section() -> String {
        format!(
            "{}\n\n\
             <!-- margins:mark id=baaaaaaaaaa cfi=\"epubcfi(/6/2!/4/2)\" at=2026-09-05T10:00:00Z percent=12.5 -->\n\
             > first quote\n\n\
             first thought.\n\n\
             <!-- margins:mark id=bbbbbbbbbbb cfi=\"epubcfi(/6/4!/4/6)\" at=2026-09-05T11:00:00Z percent=48.0 -->\n\
             > second quote\n\n\
             second thought.\n",
            marks::SENTINEL
        )
    }

    #[test]
    fn blob_save_preserves_marks_byte_identically() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);
        write_marked_note(book_dir, "001", "Original prose.", &two_mark_section());
        let before = marks_region(book_dir, "001");

        // A marks-unaware frontend: it edits the prose it loaded (long-form
        // body only) and saves through the ordinary path.
        let mut frontmatter = load_chapter_note(book_dir, "001").unwrap().frontmatter;
        frontmatter.created_at = None;
        frontmatter.updated_at = None;
        let saved = save_chapter_note(book_dir, &chapter, frontmatter, "Edited prose.").unwrap();

        assert_eq!(saved.body, "Edited prose.");
        assert_eq!(saved.marks.len(), 2);
        assert_eq!(marks_region(book_dir, "001"), before, "marks must be byte-identical");

        // Word count follows the long-form body only.
        assert_eq!(saved.frontmatter.word_count, count_words("Edited prose."));
        let index = read_notes_index(book_dir).unwrap();
        assert_eq!(index.chapters[0].mark_count, 2);
    }

    #[test]
    fn save_with_marks_in_the_body_uses_the_body_version() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);
        write_marked_note(book_dir, "001", "Original prose.", &two_mark_section());

        // A stale blob frontend saved back the whole body — with the user
        // hand-editing one mark's text in the textarea first.
        let edited = two_mark_section().replace("second thought.", "hand-edited thought.");
        let body = format!("Prose again.\n\n{}", edited);
        save_chapter_note(book_dir, &chapter, load_chapter_note(book_dir, "001").unwrap().frontmatter, &body)
            .unwrap();

        let raw = fs::read_to_string(
            book_dir
                .join("notes")
                .join(read_notes_index(book_dir).unwrap().chapters[0].file.clone()),
        )
        .unwrap();
        assert!(raw.contains("hand-edited thought."));
        // The file's marks region equals the body's section, byte for byte.
        assert_eq!(marks_region(book_dir, "001"), edited);
    }

    #[test]
    fn append_mark_creates_a_note_file_when_the_chapter_has_none() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);

        let mark = append_mark(
            book_dir,
            &chapter,
            Some("epubcfi(/6/2!/4/2)".into()),
            Some(33.0),
            "a quote",
            "a thought",
        )
        .unwrap();
        assert_eq!(mark.id.len(), 10);
        assert_eq!(mark.quote, "a quote");

        let loaded = load_chapter_note(book_dir, "001").unwrap();
        assert_eq!(loaded.body, "");
        assert_eq!(loaded.marks.len(), 1);
        assert_eq!(loaded.marks[0].id, mark.id);
        assert!(loaded.frontmatter.created_at.is_some());

        let index = read_notes_index(book_dir).unwrap();
        assert_eq!(index.chapters.len(), 1);
        assert_eq!(index.chapters[0].mark_count, 1);
        assert_eq!(index.chapters[0].word_count, 0);
    }

    #[test]
    fn append_mark_keeps_the_body_and_other_marks_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);
        write_marked_note(book_dir, "001", "The long-form note.", &two_mark_section());
        let before = marks_region(book_dir, "001");

        append_mark(book_dir, &chapter, None, None, "", "a fresh thought").unwrap();

        let after = marks_region(book_dir, "001");
        // Both original blocks are byte-identical prefixes of the new file.
        let a_block_start = before.find("id=baaaaaaaaaa").unwrap();
        let b_block_start = before.find("id=bbbbbbbbbbb").unwrap();
        assert!(after.contains(&before[a_block_start..b_block_start].trim_end()));
        assert!(after.ends_with("a fresh thought\n"));

        let loaded = load_chapter_note(book_dir, "001").unwrap();
        assert_eq!(loaded.body, "The long-form note.");
        assert_eq!(loaded.marks.len(), 3);
        let index = read_notes_index(book_dir).unwrap();
        assert_eq!(index.chapters[0].mark_count, 3);
        assert_eq!(index.chapters[0].word_count, 3, "long-form word count unchanged");
    }

    #[test]
    fn update_and_delete_mark_touch_only_their_own_block() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);
        write_marked_note(book_dir, "001", "Prose.", &two_mark_section());
        let before = marks_region(book_dir, "001");

        // Update the first mark.
        let loaded = load_chapter_note(book_dir, "001").unwrap();
        let mut edited = loaded.marks[0].clone();
        edited.body = "edited first thought".into();
        update_mark(book_dir, &chapter, edited).unwrap();

        let after_update = marks_region(book_dir, "001");
        assert!(after_update.contains("edited first thought"));
        let b_before = &before[before.find("id=bbbbbbbbbbb").unwrap()..];
        assert!(
            after_update.contains(b_before.trim_end()),
            "untouched mark keeps its bytes"
        );

        // Delete the first mark; the second is still untouched.
        delete_mark(book_dir, &chapter, "baaaaaaaaaa").unwrap();
        let after_delete = marks_region(book_dir, "001");
        assert!(!after_delete.contains("baaaaaaaaaa"));
        assert!(
            after_delete.contains(b_before.trim_end()),
            "untouched mark keeps its bytes"
        );
        assert!(after_delete.contains("second thought."));

        let index = read_notes_index(book_dir).unwrap();
        assert_eq!(index.chapters[0].mark_count, 1);

        // Unknown ids are errors, not silent no-ops.
        assert!(update_mark(book_dir, &chapter, loaded.marks[0].clone()).is_err());
        assert!(delete_mark(book_dir, &chapter, "zzzzzzzzzzz").is_err());
    }

    #[test]
    fn unparsable_content_in_the_marks_section_survives_saves() {
        let tmp = tempfile::tempdir().unwrap();
        let book_dir = tmp.path();
        let chapter = seed_book(book_dir);
        write_marked_note(
            book_dir,
            "001",
            "Prose.",
            &format!(
                "{}\n\nstray line\n\n<!-- margins:mark id= oops -->\n> broken\n\n{}",
                marks::SENTINEL,
                // Starts with its own sentinel line — unparsable junk from
                // a hand edit, preserved verbatim inside the section.
                &two_mark_section()[two_mark_section().find("<!--").unwrap()..]
            ),
        );
        let before = marks_region(book_dir, "001");

        save_chapter_note(
            book_dir,
            &chapter,
            load_chapter_note(book_dir, "001").unwrap().frontmatter,
            "New prose.",
        )
        .unwrap();

        assert_eq!(marks_region(book_dir, "001"), before);
    }
}
