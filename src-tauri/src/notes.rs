use crate::models::{ChapterMeta, ChapterNote, NoteFrontmatter, NotesIndex, NotesIndexEntry};
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

pub fn load_chapter_note(book_dir: &Path, chapter_key: &str) -> Result<ChapterNote, NotesError> {
    let notes_dir = book_dir.join("notes");
    let index: NotesIndex = if notes_dir.join("_index.json").exists() {
        serde_json::from_str(&fs::read_to_string(notes_dir.join("_index.json"))?)?
    } else {
        NotesIndex { chapters: vec![] }
    };

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

    Ok(ChapterNote {
        frontmatter: NoteFrontmatter {
            book_id: meta.id,
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
        body: default_body(&chapter.title),
        path: String::new(),
    })
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

    let now = Utc::now();
    if path.exists() {
        if let Ok(existing) = parse_note_file(&path, &chapter.key) {
            frontmatter.created_at = existing.frontmatter.created_at;
        }
    } else {
        frontmatter.created_at = Some(now);
    }
    frontmatter.updated_at = Some(now);
    frontmatter.word_count = count_words(body);

    let content = render_note(&frontmatter, body)?;
    fs::write(&path, &content)?;

    let mut index: NotesIndex = if notes_dir.join("_index.json").exists() {
        serde_json::from_str(&fs::read_to_string(notes_dir.join("_index.json"))?)?
    } else {
        NotesIndex { chapters: vec![] }
    };

    index.chapters.retain(|e| e.chapter_key != chapter.key);
    index.chapters.push(NotesIndexEntry {
        chapter_key: chapter.key.clone(),
        file: relative_path.clone(),
        chapter_index: chapter.index,
        chapter_title: chapter.title.clone(),
        word_count: frontmatter.word_count,
        updated_at: frontmatter.updated_at,
    });
    index.chapters.sort_by_key(|e| e.chapter_index);

    let raw = serde_json::to_string_pretty(&index)?;
    fs::write(notes_dir.join("_index.json"), raw)?;

    Ok(ChapterNote {
        frontmatter,
        body: body.to_string(),
        path: path.display().to_string(),
    })
}

fn parse_note_file(path: &Path, chapter_key: &str) -> Result<ChapterNote, NotesError> {
    let raw = fs::read_to_string(path)?;
    let (yaml, body) = split_frontmatter(&raw)?;
    let mut frontmatter: NoteFrontmatter = serde_yaml::from_str(&yaml)?;
    frontmatter.chapter_key = chapter_key.to_string();
    Ok(ChapterNote {
        frontmatter,
        body: body.trim_start_matches('\n').to_string(),
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

fn render_note(frontmatter: &NoteFrontmatter, body: &str) -> Result<String, NotesError> {
    let yaml = serde_yaml::to_string(frontmatter)?;
    Ok(format!("---\n{yaml}---\n\n{body}"))
}

fn default_body(chapter_title: &str) -> String {
    format!("# {chapter_title} — Summary\n\n")
}

pub fn count_words(text: &str) -> usize {
    text.split_whitespace()
        .filter(|w| !w.starts_with('#'))
        .count()
}

fn slugify(title: &str) -> String {
    let lower = title.to_lowercase();
    let re = Regex::new(r"[^a-z0-9]+").unwrap();
    let slug = re.replace_all(&lower, "-");
    slug.trim_matches('-').chars().take(48).collect()
}
