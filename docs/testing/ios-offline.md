# Testing offline reading on iOS

This document is the acceptance record for offline reading on iOS. The
contract lives in `docs/architecture.md`; the on-disk refuse rules and
the EPUB mirror (a derived copy outside the library tree) live in
`docs/storage.md`.

Every row: the expected result within the bound; no spinner without a
label; no alert titled "Something went wrong".

## Simulator fixtures (DEBUG)

Launch env vars, usually combined with `MARGINS_IMPORT_FIXTURE`:

| Variable | Effect |
| --- | --- |
| `MARGINS_EVICT_FIXTURE=source` | Replace `source.epub` with a `.name.icloud` placeholder |
| `MARGINS_EVICT_FIXTURE=position` | Same for `position.json` |
| `MARGINS_EVICT_FIXTURE=meta` | Same for `meta.json` (grid omits the book) |
| `MARGINS_OFFLINE_FIXTURE=1` | Pin connectivity offline (advisory only) |
| `MARGINS_OPEN_FIXTURE=reader` | After import, open the book as a user would |

`make ios-build` is the compile check. Device rows below need a signed
install and Airplane Mode.

## Acceptance matrix (device, Airplane Mode)

| # | Setup | Action | Expect | Bound |
|---|---|---|---|---|
| A1 | Book read on this iPhone before | Cold launch | Grid with covers and progress | 2 s |
| A2 | A1 | Tap → Continue reading | Reader at the saved page | As online |
| A3 | A2 | Page, add a mark, type a chapter note, background | All on disk; uploads once Airplane Mode is off (check on the Mac) | — |
| A4 | Book imported on the Mac, never tapped here | Cold launch | "1 book waiting for iCloud — offline"; no tile | 2 s |
| A5 | `source.epub` evicted via Files, never opened here | Tap → Download | "…isn't downloaded to this iPhone…" | 1 s |
| A6 | A5, but opened here once before the eviction | Tap → Continue reading | Reader opens (mirror) | As online |
| A7 | Mac rewrote `position.json` since the last iPhone launch | Open the book | Chapter 1; position saves; no hang | 2 s |
| A8 | Mac saved a note since the last iPhone launch | Open that chapter's note editor | Not-downloaded message in the editor; autosave refused; nothing written | 1 s |
| A9 | A8 | Airplane Mode off, foreground | Note downloads; editor shows the Mac's text | 30 s |
| A10 | Any | Airplane Mode on for five minutes mid-read | Paging, marks, position unaffected | — |
| A11 | Offline | Import from Files | Lands; readable at once (mirror) | — |
| A12 | Member of a club | Cold launch | Library first; Clubs tab reports its own error | 2 s |
