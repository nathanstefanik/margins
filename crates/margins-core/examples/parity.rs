//! Parity driver for the Rust core (docs/apple-only-plan.md Phase 2 step 6).
//!
//! Runs a fixed scripted sequence against a working library directory and
//! writes (a) a snapshot of the whole tree after every mutating stage and
//! (b) JSON/markdown reports of the API outputs. The Swift driver in
//! `apple/Sources/parity` runs the byte-for-byte same sequence;
//! `scripts/parity-compare.py` proves the outputs agree.
//!
//! Usage:
//!   parity --library <dir> --out <dir> [--fixture <epub>]
//!   parity seed --library <dir> --fixture <epub>
//!
//! `seed` imports a fixture and saves two notes with marks, producing the
//! committed `fixtures/parity-library/` sample (Rust-written, so the Swift
//! core must open it as-is).

use margins_core::compile::{compile_book_notes, render_markdown};
use margins_core::library::Library;
use margins_core::models::{NoteFrontmatter, ReadingPosition};
use margins_core::notes;
use serde_json::json;
use std::path::{Path, PathBuf};

/// Query 1 hits note content; queries 2 and 3 derive from the book's own
/// metadata (first title word, last author word) so the search leg is
/// meaningful for any fixture.
fn search_queries(meta: &margins_core::models::BookMeta) -> Vec<String> {
    let title_word = meta
        .title
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string();
    let author_word = meta
        .author
        .split_whitespace()
        .last()
        .unwrap_or_default()
        .to_string();
    vec!["xylophone".into(), title_word, author_word]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("seed") => seed(&parse_args(&args[2..])),
        Some(_) | None => run(&parse_args(&args[1..])),
    }
}

struct Args {
    library: PathBuf,
    out: Option<PathBuf>,
    fixture: Option<PathBuf>,
}

fn parse_args(args: &[String]) -> Args {
    let mut library = None;
    let mut out = None;
    let mut fixture = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--library" => {
                i += 1;
                library = Some(PathBuf::from(&args[i]));
            }
            "--out" => {
                i += 1;
                out = Some(PathBuf::from(&args[i]));
            }
            "--fixture" => {
                i += 1;
                fixture = Some(PathBuf::from(&args[i]));
            }
            other => panic!("unknown argument: {other}"),
        }
        i += 1;
    }
    Args {
        library: library.expect("--library is required"),
        out,
        fixture,
    }
}

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).expect("snapshot root");
    fn walk(src: &Path, dst: &Path) {
        for entry in std::fs::read_dir(src).expect("read dir") {
            let entry = entry.expect("dir entry");
            let target = dst.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                std::fs::create_dir_all(&target).unwrap();
                walk(&entry.path(), &target);
            } else {
                std::fs::copy(entry.path(), &target).unwrap();
            }
        }
    }
    walk(from, to);
}

fn snapshot(library: &Path, out: &Path, name: &str) {
    copy_tree(library, &out.join("snapshots").join(name));
}

/// Resolves the chapter record for `key` off the spine, like the FFI's
/// `resolve_chapter`.
fn resolve_chapter(library: &Library, book_id: &str, key: &str) -> margins_core::models::ChapterMeta {
    let meta = library.get_book(book_id).expect("get book");
    meta.chapters
        .into_iter()
        .find(|c| c.key == key)
        .unwrap_or_else(|| panic!("unknown chapter key: {key}"))
}

fn frontmatter_for(book_id: &str, chapter: &margins_core::models::ChapterMeta, body: &str) -> NoteFrontmatter {
    NoteFrontmatter {
        book_id: book_id.to_string(),
        chapter_key: chapter.key.clone(),
        chapter_index: chapter.index,
        chapter_title: chapter.title.clone(),
        chapter_href: chapter.href.clone(),
        epub_cfi: None,
        kind: "summary".into(),
        word_count: notes::count_words(body),
        created_at: None,
        updated_at: None,
    }
}

/// The scripted sequence both drivers run. `imported` is false in
/// library mode (the working directory already holds the sample book).
fn run(args: &Args) {
    let out = args.out.clone().expect("--out is required");
    let library = Library::open(args.library.clone()).expect("open library");

    if let Some(fixture) = &args.fixture {
        library
            .import_epub_with_progress(fixture.clone(), |_, _| {})
            .expect("import");
        snapshot(&args.library, &out, "01-import");
    }

    // list
    let summaries = library.list_books().expect("list books");
    let catalog = json!(summaries
        .iter()
        .map(|s| json!({
            "id": s.id,
            "title": s.title,
            "author": s.author,
            "chapterCount": s.chapter_count,
            "notesCount": s.notes_count,
        }))
        .collect::<Vec<_>>());
    std::fs::create_dir_all(out.join("report")).unwrap();
    std::fs::write(
        out.join("report/catalog.json"),
        serde_json::to_string_pretty(&catalog).unwrap(),
    )
    .unwrap();

    let book = summaries.first().expect("library must hold one book").id.clone();
    let meta = library.get_book(&book).expect("get book");
    let book_report = json!({
        "id": meta.id,
        "title": meta.title,
        "author": meta.author,
        "language": meta.language,
        "chaptersVersion": meta.chapters_version,
        "cover": meta.cover,
        "chapters": meta.chapters.iter().map(|c| json!({
            "key": c.key,
            "index": c.index,
            "title": c.title,
            "href": c.href,
            "fragment": c.fragment,
        })).collect::<Vec<_>>(),
    });
    std::fs::write(
        out.join("report/book.json"),
        serde_json::to_string_pretty(&book_report).unwrap(),
    )
    .unwrap();

    // notes index
    let book_dir = library.book_dir(&book);
    let index = notes::read_notes_index(&book_dir).expect("notes index");
    let index_report = json!(index.chapters.iter().map(|e| json!({
        "chapterKey": e.chapter_key,
        "chapterIndex": e.chapter_index,
        "chapterTitle": e.chapter_title,
        "wordCount": e.word_count,
        "markCount": e.mark_count,
    })).collect::<Vec<_>>());
    std::fs::write(
        out.join("report/notes-index.json"),
        serde_json::to_string_pretty(&index_report).unwrap(),
    )
    .unwrap();

    // position
    let first = meta.chapters.first().expect("spine").clone();
    library
        .write_position(
            &book,
            ReadingPosition {
                chapter_key: first.key.clone(),
                epub_cfi: Some("epubcfi(/6/2!/4/2)".into()),
                percent: 42.5,
                updated_at: chrono::Utc::now(),
            },
        )
        .expect("write position");
    let position = library.read_position(&book).expect("read position");
    let position_report = json!({
        "chapterKey": position.chapter_key,
        "epubCfi": position.epub_cfi,
        "percent": position.percent,
    });
    std::fs::write(
        out.join("report/position.json"),
        serde_json::to_string_pretty(&position_report).unwrap(),
    )
    .unwrap();
    snapshot(&args.library, &out, "02-position");

    // note
    let body = "First draft of the note.\n\n# A Heading\n## Sub Heading\n\nThe xylophone motif returns here.";
    let chapter = resolve_chapter(&library, &book, &first.key);
    let frontmatter = frontmatter_for(&book, &chapter, body);
    notes::save_chapter_note(&book_dir, &chapter, frontmatter, body).expect("save note");
    library.refresh_note_index(&book);
    snapshot(&args.library, &out, "03-note");

    // mark a: cfi + percent
    let mark_a = notes::append_mark(
        &book_dir,
        &chapter,
        Some("epubcfi(/6/2!/4/2)".into()),
        Some(38.2),
        "an early quote",
        "an early thought",
    )
    .expect("append mark a");
    library.refresh_note_index(&book);
    snapshot(&args.library, &out, "04-mark-a");

    // mark b: page-anchored, no cfi, no percent
    let mark_b = notes::append_mark(
        &book_dir,
        &chapter,
        None,
        None,
        "a later quote",
        "a later thought",
    )
    .expect("append mark b");
    library.refresh_note_index(&book);
    snapshot(&args.library, &out, "05-mark-b");

    // update mark a
    let mut updated = mark_a.clone();
    updated.body = "an edited thought".into();
    updated.percent = Some(40.0);
    notes::update_mark(&book_dir, &chapter, updated).expect("update mark");
    library.refresh_note_index(&book);
    snapshot(&args.library, &out, "06-mark-update");

    // delete mark b
    notes::delete_mark(&book_dir, &chapter, &mark_b.id).expect("delete mark");
    library.refresh_note_index(&book);
    snapshot(&args.library, &out, "07-mark-delete");

    // compile + render
    let compiled = compile_book_notes(&book_dir).expect("compile");
    let compiled_report = json!({
        "bookId": compiled.book_id,
        "chaptersWithNotes": compiled.chapters_with_notes,
        "chapterCount": compiled.chapter_count,
        "totalWords": compiled.total_words,
        "chapters": compiled.chapters.iter().map(|c| json!({
            "chapterKey": c.chapter_key,
            "chapterIndex": c.chapter_index,
            "chapterTitle": c.chapter_title,
            "wordCount": c.word_count,
            "marks": c.marks.iter().map(|m| json!({
                "percent": m.percent,
                "hasCfi": m.cfi.is_some(),
                "quote": m.quote,
                "body": m.body,
            })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
        "emptyChapters": compiled.empty_chapters.iter().map(|c| c.chapter_key.clone()).collect::<Vec<_>>(),
    });
    std::fs::write(
        out.join("report/compiled.json"),
        serde_json::to_string_pretty(&compiled_report).unwrap(),
    )
    .unwrap();

    let default_render = render_markdown(&compiled, &Default::default());
    std::fs::write(out.join("report/render-default.md"), default_render).unwrap();
    let options_render = render_markdown(
        &compiled,
        &margins_core::models::ExportOptions {
            include_toc: false,
            include_stats: false,
            include_empty_chapters: true,
            demote_headings: false,
        },
    );
    std::fs::write(out.join("report/render-options.md"), options_render).unwrap();

    // search
    let mut search_report = Vec::new();
    for query in search_queries(&meta) {
        let hits = library.search_notes(&query).expect("search");
        search_report.push(json!({
            "query": query,
            "hits": hits.iter().map(|h| json!({
                "bookId": h.book_id,
                "chapterKey": h.chapter_key,
                "chapterIndex": h.chapter_index,
                "chapterTitle": h.chapter_title,
                "snippet": h.snippet,
                "wordCount": h.word_count,
                "kind": h.kind,
                "score": h.score,
                "snippetRanges": h.snippet_ranges.iter().map(|r| json!({
                    "start": r.start,
                    "end": r.end,
                })).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        }));
    }
    std::fs::write(
        out.join("report/search.json"),
        serde_json::to_string_pretty(&search_report).unwrap(),
    )
    .unwrap();

    // clear notes
    notes::clear_book_notes(&book_dir).expect("clear notes");
    library.refresh_note_index(&book);
    snapshot(&args.library, &out, "08-clear");

    // remove book
    library.remove_book(&book).expect("remove book");
    snapshot(&args.library, &out, "09-remove");
}

/// Seeds `fixtures/parity-library/`: import with the Rust core, save two
/// notes with marks, save a position, and stop. What lands on disk is
/// committed as the read-compatibility sample.
fn seed(args: &Args) {
    let fixture = args.fixture.clone().expect("seed needs --fixture");
    let library = Library::open(args.library.clone()).expect("open library");
    let meta = library
        .import_epub_with_progress(fixture, |_, _| {})
        .expect("import");

    let book_dir = library.book_dir(&meta.id);
    let first = meta.chapters.first().expect("spine").clone();
    let third = meta.chapters.get(2).expect("at least three chapters").clone();

    let body_a = "Notes on the opening.\n\nThe xylophone motif begins here — a phrase to search for later.";
    let chapter_a = resolve_chapter(&library, &meta.id, &first.key);
    let frontmatter_a = frontmatter_for(&meta.id, &chapter_a, body_a);
    notes::save_chapter_note(&book_dir, &chapter_a, frontmatter_a, body_a).expect("save note a");
    notes::append_mark(
        &book_dir,
        &chapter_a,
        Some("epubcfi(/6/2!/4/2)".into()),
        Some(12.5),
        "opening line",
        "first thought",
    )
    .expect("append mark");
    library.refresh_note_index(&meta.id);

    let body_b = "Thoughts on the third chapter, written after a reread.";
    let chapter_b = resolve_chapter(&library, &meta.id, &third.key);
    let frontmatter_b = frontmatter_for(&meta.id, &chapter_b, body_b);
    notes::save_chapter_note(&book_dir, &chapter_b, frontmatter_b, body_b).expect("save note b");
    notes::append_mark(
        &book_dir,
        &chapter_b,
        None,
        None,
        "a passage",
        "a later thought",
    )
    .expect("append mark");
    library.refresh_note_index(&meta.id);

    let second = meta.chapters.get(1).expect("spine[1]").clone();
    library
        .write_position(
            &meta.id,
            ReadingPosition {
                chapter_key: second.key.clone(),
                epub_cfi: None,
                percent: 25.0,
                updated_at: chrono::Utc::now(),
            },
        )
        .expect("write position");

    println!("seeded {} ({})", meta.title, meta.id);
}
