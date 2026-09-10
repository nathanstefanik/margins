//! Writes note files with the Rust core so the Swift port can use them as
//! golden fixtures (docs/apple-only-plan.md Phase 2 step 3). Temporary;
//! deleted with the crates in step 7.
//!
//!     cargo run -p margins-core --example capture_fixtures -- <out_dir>

use chrono::{DateTime, Utc};
use margins_core::models::{BookMeta, ChapterMeta, NoteFrontmatter};
use margins_core::notes;
use std::fs;
use std::path::PathBuf;

fn at(raw: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(raw).unwrap().with_timezone(&Utc)
}

fn chapter(key: &str, index: usize, title: &str) -> ChapterMeta {
    ChapterMeta {
        key: key.into(),
        index,
        title: title.into(),
        href: format!("OEBPS/chapter{index}.xhtml"),
        fragment: None,
    }
}

fn frontmatter(chapter: &ChapterMeta, epub_cfi: Option<&str>) -> NoteFrontmatter {
    NoteFrontmatter {
        book_id: "a1b2c3d4e5f6a1b2c3d4e5f6".into(),
        chapter_key: chapter.key.clone(),
        chapter_index: chapter.index,
        chapter_title: chapter.title.clone(),
        chapter_href: chapter.href.clone(),
        epub_cfi: epub_cfi.map(str::to_string),
        kind: "summary".into(),
        word_count: 0,
        created_at: Some(at("2026-08-29T12:00:00Z")),
        updated_at: Some(at("2026-08-29T12:30:00Z")),
    }
}

fn main() {
    let out = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let book = out.join("book");
    fs::create_dir_all(book.join("notes/chapters")).unwrap();

    let chapters = vec![
        chapter("001", 0, "Introduction"),
        chapter("002", 1, "The Market"),
        chapter("003", 2, "A Title: With / Punctuation!"),
    ];
    let meta = BookMeta {
        id: "a1b2c3d4e5f6a1b2c3d4e5f6".into(),
        title: "Sample Book".into(),
        author: "Test Author".into(),
        language: Some("en".into()),
        added_at: at("2026-09-02T10:00:00Z"),
        source_filename: "sample.epub".into(),
        chapters: chapters.clone(),
        cover: Some("cover.jpg".into()),
        progress_percent: None,
        chapters_version: 1,
    };
    fs::write(
        book.join("meta.json"),
        serde_json::to_string_pretty(&meta).unwrap(),
    )
    .unwrap();
    notes::write_empty_index(&book).unwrap();

    // 1. A plain note.
    notes::save_chapter_note(
        &book,
        &chapters[0],
        frontmatter(&chapters[0], None),
        "# Introduction — Summary\n\nYour notes on this chapter.\n\nA second paragraph.",
    )
    .unwrap();

    // 2. A note with marks, one page-anchored and one with a range CFI.
    notes::save_chapter_note(
        &book,
        &chapters[1],
        frontmatter(&chapters[1], None),
        "Long-form thoughts about the market.",
    )
    .unwrap();
    notes::append_mark(
        &book,
        &chapters[1],
        Some("epubcfi(/6/14!/4/2/10,/1:0,/1:42)".into()),
        Some(38.2),
        "optional quoted selection from the book",
        "The quick thought.",
    )
    .unwrap();
    notes::append_mark(&book, &chapters[1], None, None, "a highlight with no note", "").unwrap();

    // 3. A note carrying an epub_cfi, and a title that exercises slugify.
    notes::save_chapter_note(
        &book,
        &chapters[2],
        frontmatter(&chapters[2], Some("epubcfi(/6/6!/4/2/1:0)")),
        "Anchored note body.",
    )
    .unwrap();

    // Frontmatter emitted straight from serde_yaml, both with and without
    // the optional fields, so the Swift codec can be checked in isolation.
    fs::write(
        out.join("frontmatter-full.yaml"),
        serde_yaml::to_string(&frontmatter(&chapters[2], Some("epubcfi(/6/6!/4/2/1:0)"))).unwrap(),
    )
    .unwrap();
    let mut bare = frontmatter(&chapters[0], None);
    bare.created_at = None;
    bare.updated_at = None;
    bare.chapter_title = "123".into(); // a title YAML would read as a number
    fs::write(
        out.join("frontmatter-bare.yaml"),
        serde_yaml::to_string(&bare).unwrap(),
    )
    .unwrap();

    println!("wrote fixtures to {}", out.display());
}
