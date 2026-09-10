# Storage layout

Margins stores everything as plain files under a single library root. The layout is designed for:

1. **Scale** — hundreds of notes per book, hundreds of books, without a database
2. **Portability** — copy the folder to an external drive or sync target
3. **Agent traversal** — predictable paths, JSON indexes, markdown bodies

## Default locations

| OS | Default data dir |
|----|------------------|
| macOS | `~/Library/Application Support/margins` |
| iOS | the app's iCloud Documents container when an iCloud account is available, else local `Documents/Library` (resolved per launch; see `docs/architecture.md`) |

Override the app data directory with `MARGINS_DATA_DIR`, or point `MARGINS_LIBRARY_ROOT` at a
synced folder. The macOS directory picker (`R` or `:root`) saves the selected path in
`{data_dir}/config.json`; the library files themselves stay under the selected directory. When
both are present, `MARGINS_LIBRARY_ROOT` takes precedence over the saved path.

## Tree

```
{library_root}/
  index.json                 # catalog of all books (regenerated)
  books/
    {book_id}/               # 24-char content hash prefix
      meta.json              # title, author, chapter spine, cover file name
      source.epub            # imported copy
      cover.jpg              # extracted cover (extension follows the image type)
      position.json          # reading position (chapter, CFI, percent)
      README.md              # orientation
      notes/
        _index.json          # machine index of chapter notes
        chapters/
          001-introduction.md
          002-the-market.md
```

Imports are assembled in hidden `.importing-*` directories under `books/` and renamed into
place only after all book files are written. The catalog ignores these directories, so an
interrupted import cannot appear as a book; abandoned staging directories can be removed safely.

## Chapter metadata

`meta.json` holds the book's spine as a list of chapters, alongside a
`chapters_version` for the whole book:

```json
{
  "chapters_version": 2,
  "chapters": [
    {
      "key": "009",
      "index": 8,
      "title": "Book II. An Unfortunate Gathering",
      "href": "OEBPS/28054-h-7.htm.html",
      "fragment": "pgepubid00012",
      "matter": "body",
      "level": 1,
      "sections": [
        {
          "title": "Book II. An Unfortunate Gathering",
          "fragment": "pgepubid00012",
          "level": 1
        },
        {
          "title": "Chapter I. They Arrive At The Monastery",
          "fragment": "pgepubid00013",
          "level": 2
        }
      ]
    }
  ]
}
```

- `key` is the chapter's spine position and is the anchor for everything
  else: note file names, `notes/_index.json`, note frontmatter, and
  `position.json`. It never changes for a given EPUB.
- `href` is the in-zip path of the spine item, always **without** a
  fragment — both readers match the renderer's relocation events against it.
- `fragment` (optional) is the first section's anchor: the anchor id where
  the chapter starts inside that file, taken from the book's TOC. Jump
  targets are `href#fragment` when it is present, which matters for books
  that pack several chapters into one file. Absent when the book has no TOC
  entry for the file.
- `matter` is `cover`, `front`, `body`, or `back` — where the file sits in
  the book's structure. Absent (`.body`) in files written before v2.
- `level` is the outline depth of `title` (`sections[0].level` when present,
  else 0): 0 for a part or volume, 1 for a book (or a chapter when the book
  has no parts), and deeper for leaves.
- `sections` lists **every** TOC entry that targets the file, in reading
  order. A file holding "Book II" and its first chapter has two sections;
  the UI shows both, both open the same chapter key at different anchors,
  and the chapter note for the key is shared. Sub-file chapters do not get
  their own note file because keys are file positions. Empty when the TOC
  has no entry for the file; when non-empty,
  `sections[0] == { title, fragment, level }` matches the top-level fields.

Titles resolve from the first source that has one: the file's first TOC label
(EPUB3 nav document, else NCX), the file's first `<h1>`–`<h3>`, the file's
`<title>`, then `"Chapter {n}"`. A `<title>` shared verbatim by three or more
chapters, equal to the book's own title, or beginning "The Project Gutenberg
eBook" is a template rather than a name and is skipped — Gutenberg's
Ebookmaker stamps one `<title>` into every file. A whole title wrapped in one
pair of straight or curly double quotes (`"Cover"`) has the pair stripped.

### Classification

`matter` is decided by the first signal that names the file:

1. Book-level landmarks (`<nav epub:type="landmarks">` anchors) and, for
   EPUB2, the OPF `<guide>`: `bodymatter`/`text` start Body, `backmatter`
   starts Back, `cover` is Cover, and `frontmatter`/`titlepage`/`toc`/
   `copyright-page` are Front. Landmarks win over the guide.
2. The document's own `epub:type` (on `<body>` or the first `<section>`,
   scanned in the file's first 8 KB).
3. Cover shape: a file with an `<img>` or `<svg>` and under 40 characters of
   visible text (Gutenberg's `wrap0000.html`).
4. Title heuristics, applied only to the run of files before the first Body
   file (front titles) and the trailing run after the last Body file (back
   titles): "Introduction" after chapter 3 stays Body, and "Prologue" is
   never Front by title.
5. Position: Body begins at the first file not classified Cover/Front by
   2–4; Back is the maximal trailing run classified Back by 2–4.

A file whose section label starts with `part`, `book`, `volume`, or
`chapter`, or with a number or Roman numeral ("1. Fyodor", "IV. The
Fourth"), is Body regardless of the title heuristics. A book with no Body
files at all becomes Body from its first non-Cover file.

### `chapters_version`

`chapters_version` in `meta.json` records which parser produced `chapters`
(absent means 0; 1 added TOC-derived titles and fragments; 2 added `matter`,
`level`, and `sections`). When the library scan finds a book below the
current version it re-parses the retained `source.epub`, rewrites
`chapters`, and bumps the field. The spine is unchanged by a re-parse, so
keys keep pointing at the same notes and reading position; only the outline
metadata improves. A missing or corrupt `source.epub` leaves the book
exactly as it was.

Notes keep the chapter title captured when they were saved, so the compiled
notes page and export prefer the spine's title for a matching key and fall
back to frontmatter only for keys the spine no longer has. Note files are
never rewritten by the upgrade. Saving a note whose chapter has been
retitled renames the existing file to match the new slug (one file per
chapter) rather than leaving the old one stranded.

## Covers

At import time the core extracts the EPUB cover image to `books/{book_id}/cover.{ext}`
(`.jpg`, `.png`, `.gif`, `.svg`, or `.webp`, following the image's media type). The file
name is recorded as `cover` in `meta.json` and in each `index.json` entry; books without
a cover simply have no file and `cover: null`.

Cover detection order:

1. EPUB3: manifest item with `properties="cover-image"`
2. EPUB2: `<meta name="cover" content="manifest-id"/>`
3. Fallback: the first manifest item with an `image/*` media type

The library scan backfills covers for books imported before extraction existed: if
`meta.json` has no `cover`, the retained `source.epub` is re-probed and any cover found
is written and recorded. A missing or corrupt `source.epub` never fails the scan — the
book just stays coverless.

## Reading position

`books/{book_id}/position.json` records where the reader left off, debounced while
reading and written on chapter/book changes:

```json
{
  "chapter_key": "002",
  "epub_cfi": "epubcfi(/6/6!/4/2/1:0)",
  "percent": 42.5,
  "updated_at": "2026-09-02T10:00:00Z"
}
```

- `epub_cfi` locates the exact page within the chapter (omitted if unknown)
- `percent` is the whole-book completion, clamped to 0–100
- Opening a book normally resumes here; opening a specific chapter jumps explicitly
- A missing or corrupt file is treated as "never opened" — the reader starts at chapter 1

## Chapter note format

Each note is a markdown file with YAML frontmatter:

```markdown
---
book_id: a1b2c3d4e5f6
chapter_key: '001'
chapter_index: 0
chapter_title: Introduction
chapter_href: OEBPS/chapter01.xhtml
epub_cfi: null
kind: summary
word_count: 98
created_at: 2026-08-29T12:00:00Z
updated_at: 2026-08-29T12:30:00Z
---

# Introduction — Summary

Your notes on this chapter.
```

### Why this shape

- **One file per chapter** — plain text throughout: read `_index.json` first, or `glob **/*.md`
- **Frontmatter** — structured metadata without a DB; easy to parse in any language
- **`_index.json`** — O(1) lookup of which chapters have notes and word counts
- **`index.json`** — library-wide catalog for batch operations

### Marks section

Quick, CFI-anchored notes ("marks") live inside the chapter note file,
below an optional sentinel — no parallel store, still one file per chapter:

```markdown
---
book_id: a1b2c3
chapter_key: '003'
...existing frontmatter...
---

The long-form, contemplative chapter note. Unchanged semantics: this is
exactly what the notes panes edit.

<!-- margins:marks -->

<!-- margins:mark id=b01j8q3k2m cfi="epubcfi(/6/14!/4/2/10,/1:0,/1:42)" at=2026-09-05T14:02:11Z percent=38.2 -->
> optional quoted selection from the book

The quick thought.

<!-- margins:mark id=b01j8qk9xn cfi="" at=2026-09-05T14:07:31Z -->
> a highlight with no note: the blockquote alone is the whole mark
```

Rules:

- **Everything above the first `<!-- margins:marks -->` line is the
  long-form body**, byte-identical to what a frontend that knows nothing
  about marks would write. A second sentinel inside a mark body is just
  text.
- Each mark is one HTML comment with attributes: `id`, `cfi` (range CFI,
  empty string when page-anchored), `at` (RFC3339, second precision), and
  optional `percent` (0–100, one decimal). The block's content is an
  optional `>`-blockquote (the quoted selection) followed by body
  paragraphs; a block with neither is invalid.
- **`id` is 10 lowercase Crockford-base32 characters, time-ordered** —
  sortable in files, unique without coordination, safe in HTML comments and
  shell pipelines.
- **Ordering on disk is append order.** Readers needing reading order sort
  by `percent` (then `cfi`, then `id`); marks without a percent go last.
- **Editing or deleting a mark rewrites only its block** — untouched marks
  keep their exact bytes. New/edited blocks are written in the canonical
  form above.
- **Losslessness beats tidiness.** Unparsable content inside the section
  (a stray line, a hand-mangled comment) is preserved verbatim on
  round-trip as a raw block, never dropped. Note: raw blocks stay on disk
  and are visible to file editors, but the frontends' strips render parsed
  marks only — a typed-in-prose `<!-- margins:marks -->` line starts a
  marks section, so what follows it lives on disk as raw blocks rather
  than in the long-form body.
- **Blob frontends cannot destroy marks.** `saveChapterNote` treats the
  incoming body as authoritative for any marks section it contains (so a
  stale frontend saving back what it loaded — possibly with hand edits —
  still lands those marks); a body without a sentinel leaves the marks on
  disk untouched. Marks-aware frontends go through `appendMark`,
  `updateMark`, and `deleteMark` instead of rewriting prose.

`_index.json` entries carry `mark_count` alongside `word_count` (absent
field reads as 0 in indexes written before marks existed). `word_count`
counts the long-form body only; marks are not included.

### Clearing a book's notes

Clearing all notes for a book (both frontends expose it behind a confirmation
prompt) deletes every file under `notes/chapters/` and rewrites `_index.json`
to empty. Everything else about the book — `meta.json`, `source.epub`,
`position.json` — is untouched, and the search index drops the cleared notes
on its next refresh.

## Compiled notes page & markdown export

Both frontends can show a per-book **notes page** that compiles every
chapter note in spine order (`MarginsCore/Compile.swift`, reading
`meta.json` + `notes/_index.json` + the note files). Exports are **derived
artifacts**: the rendered markdown (`{author} — {title} — notes.md`) is
written wherever the user chooses and nothing new is stored in the library
tree — recompiling is always possible from the note files, so deleting an
export never loses data.

## Sync workflow

1. Point the library root at a synced folder (`MARGINS_LIBRARY_ROOT`, or
   the macOS directory picker), or let iOS use its iCloud Documents
   container.
2. Read on machine A; notes write as plain files.
3. The sync folder (iCloud, Dropbox, rsync, an external drive) replicates
   to machine B.

On iOS, writes inside the ubiquity container are wrapped in
`NSFileCoordinator` (`FileStore`) and version conflicts surface as
`NSFileVersion` conflicts rather than silently overwriting a file.
