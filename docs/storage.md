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
      meta.json              # title, author, chapter spine
      source.epub            # imported copy
      README.md              # human/agent orientation
      notes/
        _index.json          # machine index of chapter notes
        chapters/
          001-introduction.md
          002-the-market.md
```

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

## Sync workflow

1. Set the library directory to your sync folder (`R` or `MARGINS_LIBRARY_ROOT`)
2. Read on machine A; notes write as plain files
3. Sync folder replicates to machine B or external drive
4. Use **export** / **import** for one-shot copies without changing root

Merge import keeps newer files when timestamps differ.
