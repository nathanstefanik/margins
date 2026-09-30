# Commonplace notebooks & library search

Status: first slice landed · core shared, UI iOS · Last updated: 2026-09-29

A reader develops an idea over years: a notebook called *Self-deception*
gathers passages from novels, essays, and philosophy, with the reader's own
commentary between them. Every passage opens in its original context, and
a half-remembered line can be found again from whatever words survive.

This document is the design for the first slice. The storage contract it
introduces is restated normatively in `docs/storage.md`.

## Scope

In this slice:

- **Retrieval** — forgiving search over everything the reader captured
  (mark quotes, mark thoughts, chapter notes, notebook prose) and over the
  full text of every book available on the device. Every hit opens at its
  location in the book.
- **Notebooks** — named, cross-library markdown documents where passages
  are embedded among free prose.
- **iOS UI** — a Notebooks tab, a notebook editor, "Add to Notebook…" from
  a selection, a search result, or a mark, and library search from inside
  the reader.

Deferred to later slices: macOS UI (and macOS selection capture), typed
cross-book links, rereading history, composition/export.

## Principles

- **No database.** User data is plain files in the library root. The one
  derived artifact — the full-text index — is also plain files, lives per
  device outside the library root, is never synced or backed up, and can
  be deleted at any time without losing anything.
- **Offline always.** Nothing here touches the network.
- **Marks are the passages.** A notebook references marks; it never owns a
  second copy of a passage beyond a cached quote for readability.
- **Lossless round-trips.** Editing one part of a notebook never rewrites
  bytes the edit did not touch; unknown content is preserved verbatim.

## Notebook storage

```
{library_root}/notebooks/
  _index.json
  self-deception.md
```

```markdown
---
id: 01k2m3p4q5
title: 'Self-deception'
created_at: 2026-09-29T10:00:00Z
updated_at: 2026-09-29T10:30:00Z
---

Free prose, written however you like.

<!-- margins:passage book=a1b2c3d4e5f6 chapter=014 mark=b01j8q3k2m -->
> Above all, don't lie to yourself.
> — Fyodor Dostoyevsky, *The Brothers Karamazov*, Book II

More prose. Passages can appear anywhere, in any order.
```

- `id` is a `CoreID` (10 lowercase Crockford characters, time-ordered). It
  never changes.
- The file name is `Notes.slugify(title)` + `.md` (`notebook` when the
  slug is empty; `-2`, `-3`, … on collision). Renaming a notebook renames
  its file.
- Frontmatter keys: `id`, `title`, `created_at`, `updated_at`. `title` is
  always written single-quoted (`''` escapes a quote); readers accept
  plain, single-, or double-quoted scalars. Unknown keys are preserved.
- A **passage block** is one line
  `<!-- margins:passage book=<book_id> chapter=<chapter_key> mark=<mark_id> -->`
  followed by the consecutive `>` lines under it. The last `>` line, when
  it begins with `> — `, is the citation: regenerated on write, ignored as
  quote text on read. The other `>` lines are the cached quote. A block
  ends at the first line that does not start with `>`.
- Everything else in the body is **prose**, including a passage comment
  that fails to parse (missing `book`, `chapter`, or `mark`) — it is kept
  as prose, never dropped.
- The body parses into an ordered list of segments, `prose` and `passage`.
  Each segment keeps its raw text; concatenating the segments reproduces
  the body byte for byte. Saving re-emits untouched segments verbatim and
  writes new or changed passage blocks canonically, with a blank line
  before and after.
- **Adding a passage creates a mark when needed.** From a reader selection
  or a full-text hit, the core first appends a mark (quote, empty body) to
  that chapter's note through `Notes.appendMark`, then embeds a reference
  to it. A full-text hit has no CFI, so its mark is created with `cfi`
  empty; the reader backfills the CFI the first time it reveals that mark
  (see *Jump to context*).
- **Resolution.** Loading a notebook resolves every passage against its
  mark: `ok` (live quote, book title, author, chapter title), `markMissing`
  (mark deleted — the cached quote is shown with "source removed"),
  `bookMissing`, or `notDownloaded`. The live quote wins for display. A
  save refreshes a block's cached quote and citation only when they differ
  from the live mark; unresolved blocks are never rewritten.
- `_index.json` lists `{id, title, file, passage_count, word_count,
  created_at, updated_at}` per notebook. It is derived: every write
  upserts the entry, and a listing that finds files missing from the
  index (or entries whose file is gone) rebuilds it from the files.
  `word_count` counts prose only.
- **Reverse lookup** ("this mark appears in *Self-deception*") is computed
  by scanning notebooks (cached by file mtime), never stored.
- All reads and writes go through `FileStore`, so iCloud coordination and
  the refusal of evicted files apply exactly as for chapter notes.

## Search

Two engines, one screen.

### Captured search (in memory)

`SearchEngine` keeps its current contract (lazy, mtime-revalidated,
deterministic ranking, UTF-16 highlight ranges) and gains:

- **Marks.** Each mark's quote and body are one document, returned as a
  hit of kind `mark` carrying `markId` and `cfi`.
- **Notebook prose.** Each notebook's prose is one document, returned as
  a hit of kind `notebook` carrying `notebookId`.
- **Stem matching.** A query term matches a token when the token starts
  with the term (today's rule) *or* their stems are equal.
- **Typo fallback.** A term that matches nothing anywhere in the captured
  corpus is replaced by the corpus tokens within edit distance 1 (terms of
  4–7 characters) or 2 (8+), and the query runs again.

### Full-text search (plain-file index)

**Location.** `{data_dir}/text-index/` — Application Support on both
platforms, never inside the library root. The directory is marked
excluded from backup. Removing a book deletes its index; deleting the
whole directory is always safe.

```
{data_dir}/text-index/
  FORMAT                   # format version; a mismatch wipes and rebuilds
  stats.json               # {format, books: [ids], passages, tokens}
  vocab.tsv                # stem \t passage-frequency, sorted, whole library
  books/{book_id}/
    manifest.json          # {format, extractor, book_id, chapters_version,
                           #  passages, tokens, indexed_at}
    passages.jsonl         # one {"k": chapter_key, "t": text} per line
    terms.tsv              # stem \t p:tf,p:tf,… (p = passage line), sorted
```

Book ids are content hashes, so an index never goes stale against its
EPUB; it is rebuilt only when `format`, `extractor`, or the book's
`chapters_version` change.

**Extraction.** For each spine chapter in `meta.json`, read the document
from the EPUB, take the `<body>`, drop `script`/`style`/`head` content,
and split at block elements (`p`, `div`, `h1`–`h6`, `li`, `blockquote`,
`pre`, `dd`, `dt`, `td`, `tr`, `section`, `article`, `aside`, `figcaption`,
`br` as a line break) into passages. Entities are decoded (numeric and the
HTML 4 named set), whitespace collapsed. Passages longer than 1,200
characters split at sentence boundaries into chunks of at most ~800.
Passages with no tokens are dropped.

**Analysis.** Shared by index and query: tokens are runs of letters and
digits, with an internal `'`/`’` between letters kept inside the token;
tokens are case- and diacritic-folded, a trailing `'s` is removed, and
remaining apostrophes dropped. Tokens made only of ASCII letters are
stemmed with Porter2 (Snowball English); all other tokens index as their
folded form. The same function runs regardless of the book's language.

**Query.**

1. Analyze the query into terms.
2. Expand each term: its stem (weight 1.0); for the last term when it has
   3+ characters, every indexed stem with that prefix (0.8); when a stem
   is absent from `vocab.tsv`, vocabulary stems within edit distance 1
   (4–7 characters) or 2 (8+), best 10 (0.6).
3. For each indexed book in the current library, binary-search each
   expansion (or prefix range) in the memory-mapped `terms.tsv` — a stem
   covering more than 25 % of a book's passages generates no candidates;
   its contribution is counted from the passage's tokens when scoring
   candidates the rarer terms found.
4. Score passages with BM25 (k1 = 1.2, b = 0.75; IDF from `vocab.tsv` and
   `stats.json`) times the expansion weight. **Soft AND:** a passage must
   match every term when the query has one or two terms, and at least
   ⌈60 %⌉ of them otherwise; the score is multiplied by (matched ÷ total)².
5. Re-tokenize the top 200 passages and add a proximity bonus for the
   smallest token window `w` covering the `m` matched terms (score ×
   (1 + 0.5 · m / w)), doubled again when those tokens are adjacent and in
   query order — a verbatim phrase outranks a shorter passage that merely
   shares the words.
6. Return the best 50 with a snippet window and UTF-16 highlight ranges.

**Building.** Indexing a book runs off the `CoreStore` actor into a
staging directory and is committed by rename, followed by a sorted merge
of its terms into `vocab.tsv`. Removal subtracts them. If `stats.json`
disagrees with the book directories on disk (a crash between the two
steps), the vocabulary is rebuilt from the books. On iOS the app indexes
in the background after launch, imports, and download passes, reading
the EPUB from the eviction-proof mirror or a downloaded `source.epub`.
Evicted books are skipped and reported as not indexed until they
download. macOS does not build the index in this slice.

## Jump to context

- A mark with a CFI opens at the CFI, as today.
- A full-text hit, or a mark without a CFI, opens its chapter and asks
  the reader page to **reveal** the passage text: `reader.js` walks the
  rendered section's text nodes, matches the passage whitespace- and
  case-insensitively (falling back to its first sentence, then its first
  eight words), turns the match into a CFI range, displays it, and flashes
  a highlight. The page reports the CFI back; when the target was a mark
  without one, the mark's `cfi` is backfilled.

## iOS

- **Tabs:** Library · Notebooks · Clubs · Search.
- **Notebooks tab:** list (title, passage count, last edited); New
  Notebook; rename and delete (confirmed) from the context menu.
- **Notebook editor:** the document top to bottom. Prose segments are
  inline, auto-growing text fields that autosave after a short pause.
  Passage segments are cards — quote, citation, status — that open in
  context on tap and offer Move Up, Move Down, Add Note Below, and Remove
  from Notebook. The toolbar's Add Passage opens library search in picker
  mode.
- **Library search** (the Search tab, the reader's "Search Library", and
  the picker share one view): sections for Passages (marks), In Your
  Books (full text), Notebooks, Notes, and Chapters & Books. Each passage-like
  result offers "Add to Notebook…". The screen reports index progress and
  books whose text is not indexed yet.
- **Reader:** the selection menu gains "Add to Notebook…" next to Note
  and Highlight; the reader menu gains "Search Library"; the marks sheet
  shows which notebooks cite each mark and can add a mark to a notebook.

## Testing

Swift Testing in `MarginsCoreTests` / `MarginsModelTests`: notebook
round-trips and lossless edits, passage resolution states, index rebuild
from files, reverse lookup; extraction, Porter2 vectors, index build,
stemmed/typo/prefix/soft-AND/proximity queries against the Karamazov
fixture, removal and vocabulary recovery, backup exclusion; captured
search over marks and notebooks. Simulator verification of the iOS flows
through DEBUG launch fixtures — `MARGINS_NOTEBOOK_FIXTURE=1|list|reveal`
(with `MARGINS_IMPORT_FIXTURE`) seeds a notebook holding a text-indexed
passage and lands on it (`1`), the list (`list`), or the reader's
in-context reveal (`reveal`).
