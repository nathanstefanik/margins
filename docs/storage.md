# Storage layout

Margins stores everything as plain files under a single library root. The layout is designed for:

1. **Scale** — hundreds of notes per book, hundreds of books, without a database
2. **Portability** — copy the folder to an external drive or sync target
3. **Agent traversal** — predictable paths, JSON indexes, markdown bodies

## Default locations

| OS | Default data dir |
|----|------------------|
| Linux | `~/.local/share/margins` |
| macOS | `~/Library/Application Support/margins` |

Override the app data directory with `MARGINS_DATA_DIR`, or point `MARGINS_LIBRARY_ROOT` at a
synced folder. The in-app directory picker (`R` or `:root`) saves the selected path in
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
      README.md              # human/agent orientation
      notes/
        _index.json          # machine index of chapter notes
        chapters/
          001-introduction.md
          002-the-market.md
```

Imports are assembled in hidden `.importing-*` directories under `books/` and renamed into
place only after all book files are written. The catalog ignores these directories, so an
interrupted import cannot appear as a book; abandoned staging directories can be removed safely.

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

Your ~100 word chapter summary here.
```

### Why this shape

- **One file per chapter** — agents can `glob **/*.md` or read `_index.json` first
- **Frontmatter** — structured metadata without a DB; easy to parse in any language
- **`_index.json`** — O(1) lookup of which chapters have notes and word counts
- **`index.json`** — library-wide catalog for batch operations

## Compiled notes page & markdown export

Both frontends can show a per-book **notes page** that compiles every
chapter note in spine order (`margins-core`'s `compile.rs`, reading
`meta.json` + `notes/_index.json` + the note files). Exports are **derived
artifacts**: the rendered markdown (`{author} — {title} — notes.md`) is
written wherever the user chooses and nothing new is stored in the library
tree — recompiling is always possible from the note files, so deleting an
export never loses data.

## Sync workflow

1. Set the library directory to your sync folder (`R` or `MARGINS_LIBRARY_ROOT`)
2. Read on machine A; notes write as plain files
3. Sync folder replicates to machine B or external drive
4. Use **export** / **import** for one-shot copies without changing root

Merge import keeps newer files when timestamps differ.
