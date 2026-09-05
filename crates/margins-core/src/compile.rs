//! Compiles a book's per-chapter notes into one ordered document and
//! renders it as markdown. A read/compose layer over the existing note
//! files — no storage change.

use crate::models::{BookMeta, CompiledChapter, CompiledNotes, ExportOptions, Mark};
use crate::marks;
use crate::notes::{self, NotesError};
use chrono::{DateTime, Utc};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// Reads `meta.json` + `notes/_index.json`, loads each listed note, and
/// returns them in spine order. Chapters with no note file are omitted from
/// `chapters` but counted in `chapter_count`; a missing or unparsable
/// individual note is skipped rather than sinking the whole compilation
/// (same forgiving posture as `read_notes_index`).
pub fn compile_book_notes(book_dir: &Path) -> Result<CompiledNotes, NotesError> {
    let meta: BookMeta = serde_json::from_str(&fs::read_to_string(book_dir.join("meta.json"))?)?;
    let index = notes::read_notes_index(book_dir)?;
    let notes_dir = book_dir.join("notes");

    // Note frontmatter records the chapter title as it stood when the note
    // was saved, so a book whose titles were re-derived (see
    // `library::CHAPTERS_VERSION`) would show stale names here. The spine is
    // the source of truth; frontmatter only fills in for keys it no longer
    // has. Note files are left untouched on disk.
    let spine_titles: HashMap<&str, &str> = meta
        .chapters
        .iter()
        .map(|chapter| (chapter.key.as_str(), chapter.title.as_str()))
        .collect();

    let mut chapters: Vec<CompiledChapter> = Vec::new();
    let mut first_created_at: Option<DateTime<Utc>> = None;
    let mut last_updated_at: Option<DateTime<Utc>> = None;

    for entry in &index.chapters {
        let path = notes_dir.join(&entry.file);
        let Ok(note) = notes::parse_note_file(&path, &entry.chapter_key) else {
            continue;
        };
        first_created_at = earlier_of(first_created_at, note.frontmatter.created_at);
        last_updated_at = later_of(last_updated_at, note.frontmatter.updated_at);
        // Recounted from the body so the page always agrees with what it
        // displays, even for hand-edited note files.
        let word_count = notes::count_words(&note.body);
        let chapter_title = spine_titles
            .get(entry.chapter_key.as_str())
            .map(|title| title.to_string())
            .unwrap_or(note.frontmatter.chapter_title);
        let mut chapter_marks = note.marks;
        marks::sort_reading_order(&mut chapter_marks);
        chapters.push(CompiledChapter {
            chapter_key: entry.chapter_key.clone(),
            chapter_index: note.frontmatter.chapter_index,
            chapter_title,
            body: note.body,
            marks: chapter_marks,
            word_count,
            updated_at: note.frontmatter.updated_at,
        });
    }
    // Defensive re-sort; `_index.json` is already sorted on save.
    chapters.sort_by_key(|c| c.chapter_index);

    let with_notes: Vec<&str> = chapters.iter().map(|c| c.chapter_key.as_str()).collect();
    let mut empty_chapters: Vec<CompiledChapter> = meta
        .chapters
        .iter()
        .filter(|ch| !with_notes.contains(&ch.key.as_str()))
        .map(|ch| CompiledChapter {
            chapter_key: ch.key.clone(),
            chapter_index: ch.index,
            chapter_title: ch.title.clone(),
            body: String::new(),
            marks: vec![],
            word_count: 0,
            updated_at: None,
        })
        .collect();
    empty_chapters.sort_by_key(|c| c.chapter_index);

    let total_words = chapters.iter().map(|c| c.word_count).sum();
    let mut compiled = CompiledNotes {
        book_id: meta.id,
        book_title: meta.title,
        book_author: meta.author,
        chapters,
        empty_chapters,
        chapters_with_notes: 0,
        chapter_count: meta.chapters.len(),
        total_words,
        first_created_at,
        last_updated_at,
        suggested_filename: String::new(),
    };
    compiled.chapters_with_notes = compiled.chapters.len();
    compiled.suggested_filename = suggested_export_filename(&compiled);
    Ok(compiled)
}

/// Renders the compiled notes as deterministic markdown. An empty book
/// renders a "no notes" document, not an error.
pub fn render_markdown(notes: &CompiledNotes, opts: &ExportOptions) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "# Notes — {}\n\n",
        escape_markdown_text(&notes.book_title)
    ));

    out.push_str(&format!("*{}*", escape_markdown_text(&notes.book_author)));
    if opts.include_stats {
        let mut parts = vec![format!(
            "{}/{} chapters annotated",
            notes.chapters_with_notes, notes.chapter_count
        )];
        parts.push(format!("{} words", notes.total_words));
        if let Some(updated) = notes.last_updated_at {
            parts.push(format!("last updated {}", format_date(updated)));
        }
        out.push_str(&format!(" · {}", parts.join(" · ")));
    }
    out.push_str("\n\n");

    // Sections in spine order; note-less chapters join only when gaps are
    // wanted (as `_No note._` stubs).
    let mut sections: Vec<(&CompiledChapter, bool)> =
        notes.chapters.iter().map(|c| (c, false)).collect();
    if opts.include_empty_chapters {
        sections.extend(notes.empty_chapters.iter().map(|c| (c, true)));
    }
    sections.sort_by_key(|(c, _)| c.chapter_index);

    if sections.is_empty() {
        out.push_str("_No notes yet._\n");
        return out;
    }

    if opts.include_toc {
        out.push_str("## Contents\n\n");
        let mut seen: HashMap<String, usize> = HashMap::new();
        for (chapter, _) in &sections {
            let anchor = toc_anchor(chapter.chapter_index, &chapter.chapter_title, &mut seen);
            out.push_str(&format!(
                "- [{}. {}](#{})\n",
                chapter.chapter_index + 1,
                escape_markdown_text(&chapter.chapter_title),
                anchor
            ));
        }
        out.push('\n');
    }

    for (chapter, is_stub) in &sections {
        out.push_str("---\n\n");
        out.push_str(&format!(
            "## {}. {}\n",
            chapter.chapter_index + 1,
            escape_markdown_text(&chapter.chapter_title)
        ));
        if *is_stub {
            out.push_str("\n_No note._\n\n");
            continue;
        }
        if chapter.word_count > 0 || chapter.updated_at.is_some() {
            let mut parts = vec![format!("{} words", chapter.word_count)];
            if let Some(updated) = chapter.updated_at {
                parts.push(format!("updated {}", format_date(updated)));
            }
            out.push_str(&format!("\n*{}*\n", parts.join(" · ")));
        }
        let body = chapter.body.trim();
        if !body.is_empty() {
            let body = if opts.demote_headings {
                demote_headings(body)
            } else {
                body.to_string()
            };
            let body = body.trim();
            if !body.is_empty() {
                out.push('\n');
                out.push_str(body);
                out.push('\n');
            }
        }
        render_marks(&mut out, &chapter.marks, format_date);
        // Always close the section with a blank line so a trailing
        // paragraph never merges with the next `---` (setext heading).
        out.push('\n');
    }

    out
}

/// Renders a chapter's marks (already in reading order) as plain
/// markdown — blockquote for the selection, body paragraphs, and a quiet
/// italic attribution line. No HTML comments ever reach the export.
fn render_marks(out: &mut String, chapter_marks: &[Mark], format_date: fn(DateTime<Utc>) -> String) {
    if chapter_marks.is_empty() {
        return;
    }
    out.push_str("\n### Marks\n");
    for mark in chapter_marks {
        out.push('\n');
        for line in mark.quote.lines() {
            out.push_str("> ");
            out.push_str(line);
            out.push('\n');
        }
        if !mark.body.is_empty() {
            if !mark.quote.is_empty() {
                out.push('\n');
            }
            out.push_str(&mark.body);
            out.push('\n');
        }
        let mut attribution = String::from("*— ");
        if let Some(percent) = mark.percent {
            attribution.push_str(&format!("{percent:.1}% · "));
        }
        attribution.push_str(&format_date(mark.at));
        attribution.push_str("*\n");
        out.push_str(&attribution);
    }
}

/// Shared default export name: `"{author} — {title} — notes.md"`, with
/// path-hostile characters stripped so both frontends propose the same
/// safe name.
pub fn suggested_export_filename(notes: &CompiledNotes) -> String {
    format!(
        "{} — {} — notes.md",
        sanitize_filename_component(&notes.book_author),
        sanitize_filename_component(&notes.book_title)
    )
}

fn sanitize_filename_component(text: &str) -> String {
    let spaced: String = text
        .chars()
        .map(|c| {
            if matches!(
                c,
                '/' | ':' | '\\' | '<' | '>' | '"' | '|' | '?' | '*' | '\0'
            ) {
                ' '
            } else {
                c
            }
        })
        .collect();
    spaced.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// GitHub-style TOC anchor for `"{n}. {title}"`, reusing the note-file
/// slug. Collisions get `-2`, `-3`, ... suffixes in encounter order.
fn toc_anchor(chapter_index: usize, title: &str, seen: &mut HashMap<String, usize>) -> String {
    let base = notes::slugify(&format!("{}. {}", chapter_index + 1, title));
    let count = seen.entry(base.clone()).or_insert(0);
    *count += 1;
    if *count == 1 {
        base
    } else {
        format!("{base}-{count}")
    }
}

/// Escapes markdown-significant characters in titles/authors interpolated
/// into the document so a `#`-prefixed chapter title cannot forge headings.
fn escape_markdown_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' | '`' | '*' | '_' | '[' | ']' | '#' | '<' | '>' | '|' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}

/// Shifts ATX headings (`#`…`######`) down two levels so user headings
/// never collide with the document's `#`/`##` structure; capped at `h6`.
fn demote_headings(body: &str) -> String {
    body.lines()
        .map(|line| {
            let hashes = line.chars().take_while(|&c| c == '#').count();
            let rest = &line[hashes..];
            let is_heading = (1..=6).contains(&hashes)
                && (rest.is_empty() || rest.starts_with(' ') || rest.starts_with('\t'));
            if is_heading {
                format!("{}{}", "#".repeat((hashes + 2).min(6)), rest)
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_date(time: DateTime<Utc>) -> String {
    time.format("%b %-d, %Y").to_string()
}

fn earlier_of(a: Option<DateTime<Utc>>, b: Option<DateTime<Utc>>) -> Option<DateTime<Utc>> {
    match (a, b) {
        (Some(x), Some(y)) => Some(x.min(y)),
        (Some(x), None) => Some(x),
        (None, y) => y,
    }
}

fn later_of(a: Option<DateTime<Utc>>, b: Option<DateTime<Utc>>) -> Option<DateTime<Utc>> {
    match (a, b) {
        (Some(x), Some(y)) => Some(x.max(y)),
        (Some(x), None) => Some(x),
        (None, y) => y,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{BookMeta, ChapterMeta};
    use chrono::TimeZone;
    use std::path::PathBuf;

    struct TestBook {
        dir: PathBuf,
    }

    /// Writes a book directory with the given spine; notes are added by the
    /// caller via `write_note`.
    fn seed_book(dir: &Path, chapters: &[(&str, &str)]) -> TestBook {
        let spine: Vec<ChapterMeta> = chapters
            .iter()
            .enumerate()
            .map(|(i, (key, title))| ChapterMeta {
                key: (*key).into(),
                index: i,
                title: (*title).into(),
                href: format!("OEBPS/ch{i}.xhtml"),
                fragment: None,
            })
            .collect();
        let meta = BookMeta {
            id: "abc123".into(),
            title: "Sample Book".into(),
            author: "Test Author".into(),
            language: Some("en".into()),
            added_at: Utc::now(),
            source_filename: "sample.epub".into(),
            chapters: spine,
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
        notes::write_empty_index(dir).unwrap();
        TestBook {
            dir: dir.to_path_buf(),
        }
    }

    impl TestBook {
        /// Writes a note file with fixed frontmatter dates plus its index
        /// entry — bypassing `save_chapter_note` so timestamps are
        /// deterministic for the snapshot test.
        fn write_note(&self, key: &str, index: usize, title: &str, body: &str) {
            let updated = fixed_date(1_700_000_000 + index as i64 * 86_400);
            let created = fixed_date(1_699_000_000 + index as i64 * 86_400);
            let frontmatter = format!(
                "---\nbook_id: abc123\nchapter_key: '{key}'\nchapter_index: {index}\n\
                 chapter_title: '{title}'\nchapter_href: OEBPS/ch{index}.xhtml\nepub_cfi: null\n\
                 kind: summary\nword_count: 0\ncreated_at: {created}\nupdated_at: {updated}\n---\n"
            );
            let file = format!("chapters/{key}-note.md");
            fs::write(
                self.dir.join("notes").join(&file),
                format!("{frontmatter}\n{body}"),
            )
            .unwrap();

            let index_path = self.dir.join("notes/_index.json");
            let mut doc: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&index_path).unwrap()).unwrap();
            doc["chapters"]
                .as_array_mut()
                .unwrap()
                .push(serde_json::json!({
                    "chapter_key": key,
                    "file": file,
                    "chapter_index": index,
                    "chapter_title": title,
                    "word_count": notes::count_words(body),
                    "updated_at": updated.to_rfc3339(),
                }));
            fs::write(&index_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
        }

        /// Rewrites `_index.json` with the listed keys in the given order,
        /// to prove compilation does not trust index ordering.
        fn shuffle_index(&self, order: &[&str]) {
            let index_path = self.dir.join("notes/_index.json");
            let mut doc: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&index_path).unwrap()).unwrap();
            let chapters = doc["chapters"].as_array().unwrap().clone();
            let mut shuffled: Vec<serde_json::Value> = Vec::new();
            for key in order {
                let entry = chapters
                    .iter()
                    .find(|e| e["chapter_key"].as_str() == Some(key))
                    .unwrap();
                shuffled.push(entry.clone());
            }
            doc["chapters"] = serde_json::Value::Array(shuffled);
            fs::write(&index_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
        }
    }

    fn fixed_date(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(secs, 0).unwrap()
    }

    #[test]
    fn compile_prefers_the_spine_title_over_stale_frontmatter() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Chapter II. The Real Name")]);
        // Written before the chapter titles were re-derived, so the note
        // still carries the old name.
        book.write_note("001", 0, "Chapter 1", "Body.");

        let compiled = compile_book_notes(&book.dir).unwrap();
        assert_eq!(
            compiled.chapters[0].chapter_title,
            "Chapter II. The Real Name"
        );
    }

    #[test]
    fn compile_falls_back_to_frontmatter_for_keys_off_the_spine() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Opening")]);
        book.write_note("009", 8, "An Orphaned Note", "Body.");

        let compiled = compile_book_notes(&book.dir).unwrap();
        assert_eq!(compiled.chapters[0].chapter_title, "An Orphaned Note");
    }

    #[test]
    fn compile_orders_by_chapter_index_even_when_index_is_shuffled() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(
            tmp.path(),
            &[("001", "Introduction"), ("002", "Middle"), ("003", "End")],
        );
        book.write_note("001", 0, "Introduction", "first note body");
        book.write_note("003", 2, "End", "last note body");
        book.shuffle_index(&["003", "001"]);

        let compiled = compile_book_notes(&book.dir).unwrap();
        assert_eq!(
            compiled
                .chapters
                .iter()
                .map(|c| c.chapter_key.as_str())
                .collect::<Vec<_>>(),
            vec!["001", "003"]
        );
        assert_eq!(compiled.chapters_with_notes, 2);
        assert_eq!(compiled.chapter_count, 3);
    }

    #[test]
    fn compile_omits_noteless_chapters_but_counts_them() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(
            tmp.path(),
            &[("001", "Introduction"), ("002", "Middle"), ("003", "End")],
        );
        book.write_note("001", 0, "Introduction", "first note body");
        book.write_note("003", 2, "End", "last note body");

        let compiled = compile_book_notes(&book.dir).unwrap();
        assert_eq!(compiled.chapters.len(), 2);
        assert_eq!(compiled.chapters_with_notes, 2);
        assert_eq!(compiled.chapter_count, 3);
        assert_eq!(
            compiled
                .empty_chapters
                .iter()
                .map(|c| c.chapter_key.as_str())
                .collect::<Vec<_>>(),
            vec!["002"]
        );
        assert_eq!(
            compiled.total_words,
            compiled
                .chapters
                .iter()
                .map(|c| c.word_count)
                .sum::<usize>()
        );
        assert!(compiled.first_created_at.is_some());
        assert!(compiled.last_updated_at.is_some());
        assert!(!compiled.suggested_filename.is_empty());
    }

    #[test]
    fn compile_includes_marks_in_reading_order_and_export() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Introduction")]);
        // Marks written out of reading order on disk; the last one is
        // page-anchored (no CFI, no percent).
        let marks_section = format!(
            "{}\n\n\
             <!-- margins:mark id=bbbbbbbbbbb cfi=\"epubcfi(/6/4!/4/6)\" at=2026-09-05T11:00:00Z percent=51.0 -->\n\
             > later quote\n\n\
             later thought.\n\n\
             <!-- margins:mark id=ccccccccccc cfi=\"\" at=2026-09-05T12:00:00Z -->\n\n\
             page-anchored thought.\n\n\
             <!-- margins:mark id=aaaaaaaaaaa cfi=\"epubcfi(/6/2!/4/2)\" at=2026-09-05T10:00:00Z percent=38.2 -->\n\
             > a quote\n\n\
             a thought.\n",
            crate::marks::SENTINEL
        );
        let content = format!(
            "---\nbook_id: abc123\nchapter_key: '001'\nchapter_index: 0\n\
             chapter_title: 'Introduction'\nchapter_href: OEBPS/ch0.xhtml\nepub_cfi: null\n\
             kind: summary\nword_count: 2\ncreated_at: 2026-09-05T09:00:00Z\nupdated_at: 2026-09-05T09:30:00Z\n---\n\n\
             Prose body.\n\n{}",
            marks_section
        );
        fs::write(book.dir.join("notes/chapters/001-introduction.md"), &content).unwrap();
        let index_path = book.dir.join("notes/_index.json");
        let mut doc: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&index_path).unwrap()).unwrap();
        doc["chapters"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "chapter_key": "001",
                "file": "chapters/001-introduction.md",
                "chapter_index": 0,
                "chapter_title": "Introduction",
                "word_count": 2,
                "mark_count": 3,
                "updated_at": "2026-09-05T09:30:00+00:00",
            }));
        fs::write(&index_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let compiled = compile_book_notes(&book.dir).unwrap();
        let chapter = &compiled.chapters[0];
        assert_eq!(chapter.body, "Prose body.");
        let percents: Vec<Option<f64>> = chapter.marks.iter().map(|m| m.percent).collect();
        assert_eq!(
            percents,
            vec![Some(38.2), Some(51.0), None],
            "reading order: percent ascending, page-anchored last"
        );

        let export = render_markdown(&compiled, &ExportOptions::default());
        assert!(export.contains("### Marks"));
        assert!(export.contains("> a quote"));
        assert!(export.contains("page-anchored thought."));
        assert!(export.contains("*— 38.2% · "));
        assert!(
            export.contains("*— Sep 5, 2026*"),
            "percent-less mark gets a date-only attribution"
        );
        assert!(
            !export.contains("margins:mark"),
            "no HTML comments ever reach the export"
        );
    }

    #[test]
    fn compile_skips_a_corrupt_note_and_still_succeeds() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Introduction"), ("002", "Middle")]);
        book.write_note("001", 0, "Introduction", "first note body");
        book.write_note("002", 1, "Middle", "second note body");
        // Corrupt one file: no frontmatter, unparsable.
        fs::write(
            book.dir.join("notes/chapters/002-note.md"),
            "garbage without frontmatter",
        )
        .unwrap();

        let compiled = compile_book_notes(&book.dir).unwrap();
        assert_eq!(
            compiled
                .chapters
                .iter()
                .map(|c| c.chapter_key.as_str())
                .collect::<Vec<_>>(),
            vec!["001"]
        );
        // The corrupt chapter counts as note-less, not as an error.
        assert_eq!(compiled.chapters_with_notes, 1);
        assert_eq!(compiled.empty_chapters.len(), 1);
    }

    #[test]
    fn render_markdown_snapshot() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(
            tmp.path(),
            &[
                ("001", "Introduction"),
                ("002", "Skipped"),
                ("003", "The Market"),
            ],
        );
        book.write_note(
            "001",
            0,
            "Introduction",
            "Plain start.\n\n# My Heading\n## Sub heading",
        );
        book.write_note("003", 2, "The Market", "Market notes with *emphasis*.");

        let compiled = compile_book_notes(&book.dir).unwrap();
        let out = render_markdown(&compiled, &ExportOptions::default());
        let expected = "\
# Notes — Sample Book

*Test Author* · 2/3 chapters annotated · 10 words · last updated Nov 16, 2023

## Contents

- [1. Introduction](#1-introduction)
- [3. The Market](#3-the-market)

---

## 1. Introduction

*6 words · updated Nov 14, 2023*

Plain start.

### My Heading
#### Sub heading

---

## 3. The Market

*4 words · updated Nov 16, 2023*

Market notes with *emphasis*.

";
        assert_eq!(out, expected);
    }

    #[test]
    fn render_includes_empty_chapter_stubs_when_asked() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Introduction"), ("002", "Middle")]);
        book.write_note("001", 0, "Introduction", "first note body");

        let compiled = compile_book_notes(&book.dir).unwrap();
        let opts = ExportOptions {
            include_empty_chapters: true,
            ..ExportOptions::default()
        };
        let out = render_markdown(&compiled, &opts);
        assert!(out.contains("- [2. Middle](#2-middle)"));
        assert!(out.contains("## 2. Middle\n\n_No note._"));

        // Default export keeps the gaps invisible.
        let default_out = render_markdown(&compiled, &ExportOptions::default());
        assert!(!default_out.contains("Middle"));
    }

    #[test]
    fn render_empty_book_produces_a_no_notes_document() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Introduction"), ("002", "Middle")]);

        let compiled = compile_book_notes(&book.dir).unwrap();
        let out = render_markdown(&compiled, &ExportOptions::default());
        assert_eq!(
            out,
            "# Notes — Sample Book\n\n*Test Author* · 0/2 chapters annotated · 0 words\n\n_No notes yet._\n"
        );
    }

    #[test]
    fn toc_anchor_collisions_get_numeric_suffixes() {
        // Distinct chapter numbers make base slugs distinct; collisions
        // only arise from identical inputs (or future slug changes), so
        // the dedupe is exercised on the helper directly.
        let mut seen = HashMap::new();
        assert_eq!(toc_anchor(0, "Same Title", &mut seen), "1-same-title");
        assert_eq!(toc_anchor(0, "Same Title", &mut seen), "1-same-title-2");
        assert_eq!(toc_anchor(0, "Same Title", &mut seen), "1-same-title-3");
    }

    #[test]
    fn filename_helper_strips_path_hostile_characters() {
        let tmp = tempfile::tempdir().unwrap();
        let book = seed_book(tmp.path(), &[("001", "Introduction")]);
        let mut meta: BookMeta =
            serde_json::from_str(&fs::read_to_string(book.dir.join("meta.json")).unwrap()).unwrap();
        meta.title = "Weird: Title/With?Slashes*".into();
        meta.author = "Anne/Sophie: Author".into();
        fs::write(
            book.dir.join("meta.json"),
            serde_json::to_string_pretty(&meta).unwrap(),
        )
        .unwrap();

        let compiled = compile_book_notes(&book.dir).unwrap();
        let filename = suggested_export_filename(&compiled);
        assert_eq!(
            filename,
            "Anne Sophie Author — Weird Title With Slashes — notes.md"
        );
        assert!(!filename.contains('/') && !filename.contains(':'));
    }

    #[test]
    fn suggested_filename_survives_empty_strings() {
        let notes = CompiledNotes {
            book_id: "x".into(),
            book_title: String::new(),
            book_author: String::new(),
            chapters: vec![],
            empty_chapters: vec![],
            chapters_with_notes: 0,
            chapter_count: 0,
            total_words: 0,
            first_created_at: None,
            last_updated_at: None,
            suggested_filename: String::new(),
        };
        assert_eq!(suggested_export_filename(&notes), " —  — notes.md");
    }
}
