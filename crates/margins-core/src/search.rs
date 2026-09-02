//! In-memory search index over the library.
//!
//! Posture: the corpus is a personal library (hundreds of books, thousands
//! of short notes), so a hand-rolled index is plenty. If that assumption is
//! ever exceeded, swap these internals for tantivy behind the same
//! `Library::search_notes` API.
//!
//! The index is built lazily on the first query and kept warm: every query
//! re-validates each book cheaply (meta.json / notes/_index.json / note
//! file mtimes) and re-parses only what changed, so notes edited by agents
//! or external tools are picked up automatically. Saves through the core
//! refresh their book eagerly (`refresh_book`).
//!
//! Matching is AND across whitespace-separated terms; every term matches as
//! a token prefix (so "mark" finds "market" and results appear mid-word).
//! Tokens are Unicode-case-folded via `str::to_lowercase`. Ranking is
//! deterministic: field weight (chapter title > book title/author > body)
//! times term frequency, plus a phrase bonus when terms appear as adjacent
//! tokens in order; ties break by book title, then chapter index.
//!
//! Highlight ranges are half-open and measured in UTF-16 code units of the
//! string they point into (snippet or title), so UI layers can convert them
//! to native string ranges without re-running the matcher.

use crate::models::{MatchRange, NoteSearchHit, SearchHitKind};
use crate::notes;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::SystemTime;

const CHAPTER_TITLE_WEIGHT: f64 = 3.0;
const BOOK_TITLE_WEIGHT: f64 = 2.0;
const AUTHOR_WEIGHT: f64 = 2.0;
const BODY_WEIGHT: f64 = 1.0;
const PHRASE_BONUS: f64 = 2.0;

/// Snippet window: characters of context before/after the first match.
const SNIPPET_BEFORE: usize = 40;
const SNIPPET_AFTER: usize = 80;

pub struct SearchEngine {
    books: HashMap<String, IndexedBook>,
}

struct IndexedBook {
    id: String,
    title: String,
    author: String,
    title_tokens: Vec<Token>,
    author_tokens: Vec<Token>,
    chapters: Vec<IndexedChapter>,
    meta_mtime: SystemTime,
    notes_index_mtime: Option<SystemTime>,
}

struct IndexedChapter {
    key: String,
    index: usize,
    title: String,
    title_tokens: Vec<Token>,
    /// The chapter note body, if a note exists.
    body: Option<IndexedNote>,
}

struct IndexedNote {
    body: String,
    body_tokens: Vec<Token>,
    word_count: usize,
    file: String,
    mtime: SystemTime,
}

/// A word-ish run in a field, case-folded for matching, with its half-open
/// UTF-16 range in the original text.
struct Token {
    text: String,
    start16: usize,
    end16: usize,
}

fn tokenize(text: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut start16 = 0usize;
    let mut utf16 = 0usize;

    for ch in text.chars() {
        if ch.is_alphanumeric() {
            if current.is_empty() {
                start16 = utf16;
            }
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(Token {
                text: current.to_lowercase(),
                start16,
                end16: utf16,
            });
            current.clear();
        }
        utf16 += ch.len_utf16();
    }
    if !current.is_empty() {
        tokens.push(Token {
            text: current.to_lowercase(),
            start16,
            end16: utf16,
        });
    }
    tokens
}

fn count_prefix_matches(tokens: &[Token], term: &str) -> usize {
    tokens
        .iter()
        .filter(|token| token.text.starts_with(term))
        .count()
}

fn matched_ranges(tokens: &[Token], terms: &[String]) -> Vec<MatchRange> {
    tokens
        .iter()
        .filter(|token| terms.iter().any(|term| token.text.starts_with(term)))
        .map(|token| MatchRange {
            start: token.start16,
            end: token.end16,
        })
        .collect()
}

/// True when all terms appear, in order, as adjacent tokens (the last one
/// may be a partial word — a query still being typed).
fn phrase_match(tokens: &[Token], terms: &[String]) -> bool {
    if terms.len() < 2 || tokens.len() < terms.len() {
        return false;
    }
    'windows: for start in 0..=tokens.len() - terms.len() {
        for (offset, term) in terms.iter().enumerate() {
            if !tokens[start + offset].text.starts_with(term) {
                continue 'windows;
            }
        }
        return true;
    }
    false
}

fn parse_terms(query: &str) -> Vec<String> {
    query
        .split_whitespace()
        .map(|term| term.to_lowercase())
        .collect()
}

impl Default for SearchEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl SearchEngine {
    pub fn new() -> Self {
        Self {
            books: HashMap::new(),
        }
    }

    /// Drops all cached docs; the next query rebuilds from scratch.
    pub fn clear(&mut self) {
        self.books.clear();
    }

    /// Runs a query, first refreshing anything stale. Tolerates corrupt
    /// books and notes: they are skipped, never failing the whole search.
    pub fn query(&mut self, root: &Path, raw_query: &str) -> Vec<NoteSearchHit> {
        let terms = parse_terms(raw_query);
        if terms.is_empty() {
            return Vec::new();
        }
        self.validate(root);

        let mut hits: Vec<NoteSearchHit> = Vec::new();

        // Book-level targets: one hit per book whose title/author match.
        for book in self.books.values() {
            if !terms.iter().all(|term| {
                count_prefix_matches(&book.title_tokens, term) > 0
                    || count_prefix_matches(&book.author_tokens, term) > 0
            }) {
                continue;
            }
            let mut score = 0.0;
            for term in &terms {
                score += BOOK_TITLE_WEIGHT * count_prefix_matches(&book.title_tokens, term) as f64;
                score += AUTHOR_WEIGHT * count_prefix_matches(&book.author_tokens, term) as f64;
            }
            if phrase_match(&book.title_tokens, &terms) || phrase_match(&book.author_tokens, &terms)
            {
                score += PHRASE_BONUS;
            }
            hits.push(NoteSearchHit {
                book_id: book.id.clone(),
                book_title: book.title.clone(),
                book_author: book.author.clone(),
                chapter_key: String::new(),
                chapter_index: 0,
                chapter_title: String::new(),
                snippet: String::new(),
                word_count: 0,
                kind: SearchHitKind::BookTarget,
                score,
                snippet_ranges: Vec::new(),
                title_ranges: matched_ranges(&book.title_tokens, &terms),
            });
        }

        // Chapter-level hits: every term must match within the chapter's
        // own title or note body. Body evidence makes it a content hit;
        // title-only matches are pure navigation targets.
        for (book_id, book) in &self.books {
            for chapter in &book.chapters {
                let mut title_tf = 0.0;
                let mut body_tf = 0.0;
                let all_match = terms.iter().all(|term| {
                    let in_title = count_prefix_matches(&chapter.title_tokens, term);
                    let in_body = chapter
                        .body
                        .as_ref()
                        .map(|note| count_prefix_matches(&note.body_tokens, term))
                        .unwrap_or(0);
                    title_tf += in_title as f64;
                    body_tf += in_body as f64;
                    in_title > 0 || in_body > 0
                });
                if !all_match {
                    continue;
                }

                let body_matched = body_tf > 0.0;
                let mut score = CHAPTER_TITLE_WEIGHT * title_tf + BODY_WEIGHT * body_tf;
                if phrase_match(&chapter.title_tokens, &terms)
                    || chapter
                        .body
                        .as_ref()
                        .is_some_and(|note| phrase_match(&note.body_tokens, &terms))
                {
                    score += PHRASE_BONUS;
                }

                let (kind, snippet, snippet_ranges, word_count) = if body_matched {
                    let note = chapter.body.as_ref().expect("body matched");
                    let mut ranges = Vec::new();
                    let snippet = build_snippet(&note.body, &terms, &mut ranges);
                    (SearchHitKind::NoteContent, snippet, ranges, note.word_count)
                } else {
                    (SearchHitKind::ChapterTitle, String::new(), Vec::new(), 0)
                };
                let title_ranges = matched_ranges(&chapter.title_tokens, &terms);

                hits.push(NoteSearchHit {
                    book_id: book_id.clone(),
                    book_title: book.title.clone(),
                    book_author: book.author.clone(),
                    chapter_key: chapter.key.clone(),
                    chapter_index: chapter.index,
                    chapter_title: chapter.title.clone(),
                    snippet,
                    word_count,
                    kind,
                    score,
                    snippet_ranges,
                    title_ranges,
                });
            }
        }

        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.book_title.cmp(&b.book_title))
                .then_with(|| a.chapter_index.cmp(&b.chapter_index))
                .then_with(|| a.chapter_key.cmp(&b.chapter_key))
        });
        hits
    }

    /// Drops one book's cached docs so the next query rebuilds them; used
    /// after core saves to update the index in place.
    pub fn invalidate_book(&mut self, book_id: &str) {
        self.books.remove(book_id);
    }

    /// Re-reads one book from disk immediately (index update in place after
    /// a core save). Corrupt data just drops the book from the index.
    pub fn refresh_book(&mut self, root: &Path, book_id: &str) {
        self.books.remove(book_id);
        let book_dir = root.join("books").join(book_id);
        if let Some(indexed) = IndexedBook::build(&book_dir) {
            self.books.insert(book_id.to_string(), indexed);
        }
    }

    /// Cheap per-query validation: notice added/removed books, changed
    /// metadata, changed note indexes, and externally edited note bodies.
    fn validate(&mut self, root: &Path) {
        let books_dir = root.join("books");
        let mut present: Vec<String> = Vec::new();

        if let Ok(entries) = fs::read_dir(&books_dir) {
            for entry in entries.flatten() {
                let file_name = entry.file_name();
                if file_name.to_string_lossy().starts_with('.') {
                    continue;
                }
                if !entry.file_type().is_ok_and(|t| t.is_dir()) {
                    continue;
                }
                let book_dir = entry.path();
                let Some(meta_mtime) = fs::metadata(book_dir.join("meta.json"))
                    .ok()
                    .and_then(|m| m.modified().ok())
                else {
                    continue;
                };
                let id = file_name.to_string_lossy().into_owned();
                present.push(id.clone());

                let notes_index_mtime = fs::metadata(book_dir.join("notes/_index.json"))
                    .ok()
                    .and_then(|m| m.modified().ok());

                let rebuild = match self.books.get(&id) {
                    Some(indexed) => {
                        indexed.meta_mtime != meta_mtime
                            || indexed.notes_index_mtime != notes_index_mtime
                    }
                    None => true,
                };
                if rebuild {
                    if let Some(indexed) = IndexedBook::build(&book_dir) {
                        self.books.insert(id, indexed);
                    }
                    continue;
                }

                // Index is structurally current; re-check note file bodies.
                if let Some(indexed) = self.books.get_mut(&id) {
                    for chapter in &mut indexed.chapters {
                        if let Some(note) = &mut chapter.body {
                            let path = book_dir.join("notes").join(&note.file);
                            if let Ok(mtime) = fs::metadata(&path).and_then(|m| m.modified()) {
                                if mtime != note.mtime {
                                    if let Some(updated) =
                                        IndexedNote::load(&path, &note.file, &chapter.key)
                                    {
                                        *note = updated;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        self.books.retain(|id, _| present.contains(id));
    }
}

/// The book id isn't stored on IndexedBook; recover it from the root for
/// hit construction during book-level matching.
impl IndexedBook {
    fn build(book_dir: &Path) -> Option<Self> {
        let meta_raw = fs::read_to_string(book_dir.join("meta.json")).ok()?;
        let meta: crate::models::BookMeta = serde_json::from_str(&meta_raw).ok()?;

        let notes_index_path = book_dir.join("notes/_index.json");
        let notes_index: crate::models::NotesIndex = fs::read_to_string(&notes_index_path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or(crate::models::NotesIndex { chapters: vec![] });
        let notes_index_mtime = fs::metadata(&notes_index_path)
            .ok()
            .and_then(|m| m.modified().ok());

        let notes_by_key: HashMap<String, &crate::models::NotesIndexEntry> = notes_index
            .chapters
            .iter()
            .map(|entry| (entry.chapter_key.clone(), entry))
            .collect();

        let mut chapters = Vec::new();
        for chapter in &meta.chapters {
            let body = notes_by_key.get(&chapter.key).and_then(|entry| {
                IndexedNote::load(
                    &book_dir.join("notes").join(&entry.file),
                    &entry.file,
                    &chapter.key,
                )
            });
            chapters.push(IndexedChapter {
                key: chapter.key.clone(),
                index: chapter.index,
                title: chapter.title.clone(),
                title_tokens: tokenize(&chapter.title),
                body,
            });
        }

        Some(Self {
            id: meta.id,
            title_tokens: tokenize(&meta.title),
            author_tokens: tokenize(&meta.author),
            title: meta.title,
            author: meta.author,
            chapters,
            meta_mtime: fs::metadata(book_dir.join("meta.json"))
                .ok()?
                .modified()
                .ok()?,
            notes_index_mtime,
        })
    }
}

impl IndexedNote {
    /// Parses a note file; a corrupt or deleted file yields `None` (the
    /// chapter stays searchable by title). `file` is the note's path
    /// relative to the book's `notes/` directory, as stored in the index.
    fn load(path: &Path, file: &str, chapter_key: &str) -> Option<Self> {
        let note = notes::parse_note_file(path, chapter_key).ok()?;
        let mtime = fs::metadata(path).ok()?.modified().ok()?;
        Some(Self {
            body_tokens: tokenize(&note.body),
            body: note.body,
            word_count: note.frontmatter.word_count,
            file: file.to_string(),
            mtime,
        })
    }
}

/// Builds a snippet window around the first term occurrence and collects
/// the matched token ranges (UTF-16, relative to the snippet).
fn build_snippet(body: &str, terms: &[String], ranges: &mut Vec<MatchRange>) -> String {
    let tokens = tokenize(body);
    let Some(first_match) = tokens
        .iter()
        .find(|token| terms.iter().any(|term| token.text.starts_with(term)))
    else {
        return String::new();
    };

    // Window in chars, converted to byte offsets for slicing.
    let chars: Vec<(usize, char)> = body.char_indices().collect();
    let match_start_char = chars
        .iter()
        .position(|(byte, _)| *byte >= byte_index_of_utf16(body, first_match.start16))
        .unwrap_or(0);
    let start_char = match_start_char.saturating_sub(SNIPPET_BEFORE);
    let end_char = (match_start_char + SNIPPET_AFTER).min(chars.len());
    let start_byte = chars[start_char].0;
    let end_byte = if end_char < chars.len() {
        chars[end_char].0
    } else {
        body.len()
    };
    let mut snippet = body[start_byte..end_byte].to_string();
    if start_char > 0 {
        snippet.insert(0, '…');
    }
    if end_char < chars.len() {
        snippet.push('…');
    }

    for token in tokenize(&snippet) {
        if terms.iter().any(|term| token.text.starts_with(term)) {
            ranges.push(MatchRange {
                start: token.start16,
                end: token.end16,
            });
        }
    }
    snippet
}

/// Byte index of the first char at or after `offset16` UTF-16 units in.
fn byte_index_of_utf16(text: &str, offset16: usize) -> usize {
    let mut utf16 = 0usize;
    for (byte, ch) in text.char_indices() {
        if utf16 >= offset16 {
            return byte;
        }
        utf16 += ch.len_utf16();
    }
    text.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::Library;
    use crate::models::{ChapterMeta, NoteFrontmatter};
    use crate::test_fixtures::write_sample_epub_covered;

    fn setup_library(root: &Path) -> Library {
        let library = Library::open(root.join("library")).expect("open library");
        let epub =
            write_sample_epub_covered(root, "sample.epub", crate::test_fixtures::SampleCover::None);
        library
            .import_epub_with_progress(epub, |_, _| {})
            .expect("import");
        library
    }

    fn save_note(library: &Library, book_id: &str, chapter: &ChapterMeta, body: &str) {
        let frontmatter = NoteFrontmatter {
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
        };
        notes::save_chapter_note(&library.book_dir(book_id), chapter, frontmatter, body)
            .expect("save note");
        library.refresh_note_index(book_id);
    }

    fn sample_chapters(library: &Library, book_id: &str) -> Vec<ChapterMeta> {
        library.get_book(book_id).expect("book").chapters
    }

    #[test]
    fn empty_or_whitespace_query_returns_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        assert!(library.search_notes("").unwrap().is_empty());
        assert!(library.search_notes("   \t ").unwrap().is_empty());
    }

    #[test]
    fn unicode_case_folding_matches() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);

        save_note(
            &library,
            &book_id,
            &chapters[0],
            "Café culture thrives here.",
        );
        save_note(&library, &book_id, &chapters[1], "The STRAßE was quiet.");

        let hits = library.search_notes("café").unwrap();
        assert_eq!(hits.len(), 1);
        assert!(hits[0].snippet.contains("Café"));

        // "STRAßE" folds to "straße"; the query folds the same way.
        let hits = library.search_notes("straße").unwrap();
        assert_eq!(hits.len(), 1);
        assert!(hits[0].snippet.contains("STRAßE"));
    }

    #[test]
    fn prefix_matches_mid_word() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);

        // "squar" prefixes "square" in the body; the other chapter's title
        // ("The Market") must not match this term.
        save_note(
            &library,
            &book_id,
            &chapters[0],
            "The market square fills at dawn.",
        );

        let hits = library.search_notes("squar").unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, SearchHitKind::NoteContent);
    }

    #[test]
    fn chapter_title_hit_outranks_body_hit() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);

        // Chapter one's TITLE contains "Introduction"; chapter two only has
        // the word in its note body. Title hits are pure navigation.
        save_note(
            &library,
            &book_id,
            &chapters[1],
            "Introductions matter here.",
        );
        let hits = library.search_notes("introduct").unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].kind, SearchHitKind::ChapterTitle);
        assert!(hits[0].score > hits[1].score);
        assert_eq!(hits[1].kind, SearchHitKind::NoteContent);
        assert!(hits[1].snippet.contains("Introductions"));
    }

    #[test]
    fn proximity_bonus_ranks_adjacent_terms_first() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);

        save_note(
            &library,
            &book_id,
            &chapters[0],
            "Faith and doubt are twins.",
        );
        save_note(
            &library,
            &book_id,
            &chapters[1],
            "Faith doubt decided the night.",
        );

        let hits = library.search_notes("faith doubt").unwrap();
        assert_eq!(hits.len(), 2);
        // Adjacent-in-order terms carry the phrase bonus.
        assert!(hits[0].score > hits[1].score);
        assert_eq!(hits[0].chapter_key, "002");
    }

    #[test]
    fn snippet_ranges_are_valid_utf16_indices() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);

        save_note(
            &library,
            &book_id,
            &chapters[0],
            "Café culture thrives here.",
        );
        let hits = library.search_notes("café").unwrap();
        assert_eq!(hits.len(), 1);
        assert!(!hits[0].snippet_ranges.is_empty());

        let snippet16: Vec<u16> = hits[0].snippet.encode_utf16().collect();
        for range in &hits[0].snippet_ranges {
            assert!(range.start < range.end);
            assert!(range.end <= snippet16.len());
            let matched = String::from_utf16(&snippet16[range.start..range.end]).unwrap();
            assert!(matched.to_lowercase().starts_with("café"));
        }
    }

    #[test]
    fn external_note_edit_is_picked_up_on_next_query() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);
        save_note(&library, &book_id, &chapters[0], "original body text.");

        let note_path = library
            .book_dir(&book_id)
            .join("notes/chapters")
            .read_dir()
            .unwrap()
            .find(|e| e.as_ref().unwrap().path().extension().unwrap() == "md")
            .unwrap()
            .unwrap()
            .path();
        // Ensure the mtime clearly differs from the indexed snapshot.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let raw = fs::read_to_string(&note_path).unwrap();
        fs::write(&note_path, raw.replace("original", "xylophone")).unwrap();

        // The index is warm from the first query; the edit must surface.
        assert!(!library.search_notes("xylophone").unwrap().is_empty());
    }

    #[test]
    fn warm_index_matches_cold_scan() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);
        save_note(
            &library,
            &book_id,
            &chapters[0],
            "Faith and doubt are twins.",
        );

        // Warm the index, then search again (exercises the validate path).
        let warm_first = library.search_notes("doubt").unwrap();
        let warm_second = library.search_notes("faith").unwrap();

        let mut cold = SearchEngine::new();
        let cold_hits = cold.query(&tmp.path().join("library"), "faith");
        assert_eq!(cold_hits.len(), warm_second.len());
        assert_eq!(cold_hits[0].snippet, warm_second[0].snippet);
        drop(warm_first);
    }

    #[test]
    fn book_title_only_match_yields_single_book_target() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();

        // "Sample Book" is the fixture title; no chapter or note mentions it.
        let hits = library.search_notes("sample").unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, SearchHitKind::BookTarget);
        assert_eq!(hits[0].book_id, book_id);
        assert_eq!(hits[0].chapter_key, "");
        assert_eq!(hits[0].book_title, "Sample Book");
    }

    #[test]
    fn two_term_query_requires_all_terms() {
        let tmp = tempfile::tempdir().unwrap();
        let library = setup_library(tmp.path());
        let book_id = library.list_books().unwrap()[0].id.clone();
        let chapters = sample_chapters(&library, &book_id);

        save_note(&library, &book_id, &chapters[0], "Faith without doubt.");

        // AND semantics: a term that matches nothing kills the query, but
        // two scattered terms in the same note still match.
        assert!(library.search_notes("faith xylophone").unwrap().is_empty());
        assert_eq!(library.search_notes("faith doubt").unwrap().len(), 1);
        assert_eq!(library.search_notes("faith").unwrap().len(), 1);
    }
}
