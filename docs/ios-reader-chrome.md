# iOS reader chrome & typography

Status: Phases 1–2 landed · iOS only · Last updated: 2026-09-09

macOS keeps its typography popover and keyboard chrome. This document is
the iOS reader only.

## Goal

The resting reading screen looks like a printed spread: chapter title at
the top of the paper, page number at the bottom. Controls stay out of the
way until a center tap. Text size is a short internal ladder of readable
steps behind smaller/larger "A" buttons — never numbers — and it actually
changes glyph size.

## Locked behavior

**Resting page (no chrome).** Chapter title centered at the top of the
paper, page number centered at the bottom. No eye, no note, no toolbars.

**Single tap.** Existing thirds stay: left/right turn the page (and hide
chrome). Center tap toggles chrome. That tap also expands the footer from
`12` to `12 of 40`. Those counts are **this chapter's paginated pages**
(what epub.js reports). The app has no whole-book page total, only a
percent.

**Revealed chrome.** A hamburger (`line.3.horizontal`) and the new-note
button. Back lives here too (leading chevron) so leaving the reader is
not buried in a sheet. Title and page number stay put.

**Hamburger sheet.** Text size as a small-A / large-A pair — no numbers,
no slider, no ladder labels shown; the steps below are internal. Also
Contents, Marks, and chapter note — those controls lost their bars with
the old chrome. No line height, no measure.

**Paging.** Swipe still turns pages. Page-turn hides chrome again.

## Why font size felt broken

`readerStyleContents` set `html { font-size: 130% }` and
`body { font-size: inherit }`. Gutenberg-style sheets set `p { font-size:
14px }` (or similar), which ignores `%` on `html` — so the glyphs never
moved. On top of that, `readerApplyViewerWidth` widened the column with
font size (`maxWidth = lineWidth × fontSize/100`), so a size bump
changed measure instead of type. On a phone the column is already full
width, so you got neither a wider measure nor bigger type.

Fix in shared `reader.js` (helps macOS too): the root size lands on
`html` with `!important` and a rule forces
`body, p, li, div { font-size: inherit !important }`; the column width no
longer scales with font size.

**Why not `rendition.themes.fontSize`** (the original sketch): in the
bundled epub.js, `Contents#css` — which backs theme overrides — writes
the property inline on **body**, not `html`, and without `!important`.
The forced `body { font-size: inherit !important }` rule would then beat
it, and the size would never apply. Setting the root size on `html`
ourselves, per section via the content hook, is deterministic.

## iOS typography model

Five internal steps behind the A buttons, default **3** (18px — readable
body text on a phone):

| Step | px (applied to the rendition) |
|------|-------------------------------|
| 1    | 14 |
| 2    | 16 |
| 3    | 18 |
| 4    | 21 |
| 5    | 24 |

The numbers exist only in code (`ReaderPreferences.fontStep`, persisted
as `reader.fontStep`); the UI exposes smaller/larger "A" buttons that
disable at the ends of the ladder.

Line height is a fixed 1.65 (iOS passes it at apply time). Line width is
unused on iOS (`0` → full width). Side/top/bottom padding is **fixed
CSS** on `#viewer` (`2.2rem` top, `2.0rem` bottom, `1.4rem` sides), sized
so body text clears the running header and footer. There is no
`safeAreaInset` chrome, so showing buttons never reflows the page.

`ReaderPreferences` keeps the macOS `%` / line-height / measure API
untouched. The iOS sheet is `ReaderSettingsSheet` (hamburger);
`TypographySheet` is gone.

## Layout

Title, page number, hamburger, and new note are **overlays on the
paper**, not insets — the webview keeps a constant frame, so revealing
chrome cannot reflow the page. Overlay controls use a 44pt
`contentShape` so the hit survives WKWebView's bounds (the same class of
bug as the old dead eye/note buttons); the title and page number are
`allowsHitTesting(false)` so a center tap near them still hits the page
thirds instead of dead-ending on the footer.

VoiceOver: `.accessibilityAction` on the reader for "Show controls" and
"New note", so those are not gesture-only.

Tap zones are detected **in the page**: a capture-phase `click`
listener in each section iframe (and the top document) posts the tap's
parent-viewport x and width through `window.webkit.messageHandlers` —
Apple's documented web→native channel, already used for `relocated` and
`selected`. Do not try gesture recognizers here: WKWebView's private tap
recognizers starve any `UITapGestureRecognizer` attached to the
container on device (they work in the simulator — three builds were
burned proving it), the pan survives because it moves, and the view's
own `touchesEnded` never fires because WKContentView consumes content
touches. `touch-action: manipulation` in the reading CSS kills tap
delay and double-tap zoom. Swipes are a native
`UIPanGestureRecognizer` (`cancelsTouchesInView = false`).

## Files

- `apple/ios/Margins/Reader/ReaderScene.swift` — rest/revealed chrome;
  overlay header/footer; hamburger + note
- `apple/ios/Margins/Reader/ReaderSettingsSheet.swift` — font A pair,
  Serif/Sans switch, Contents, Marks, chapter note
- `apple/ios/Margins/Reader/ReaderBridge.swift` — pass step/px/face;
  drop lineWidth on iOS
- `apple/Sources/MarginsModel/ReaderPreferences.swift` — iOS `fontStep`
  1…5 and `ReaderTypeface`
- `apple/Sources/MarginsModel/Resources/reader/reader.js` — real
  font-size apply; no measure scaling
- `apple/Sources/MarginsModel/Resources/reader/reader.html` — fixed page
  margins only

## Phases

### Phase 1 — book-like chrome + text size that works (this pass)

Everything above: resting page, tap thirds, overlay chrome, hamburger
sheet with the A pair, `reader.js` apply fix, fixed `#viewer` padding.

### Phase 2 — typeface: two system faces (landed)

Sans = SF Pro, serif = New York — both pulled from the system at runtime
(`-apple-system` / `ui-serif` in the webview), nothing bundled, zero MB,
no licensing question: this is the sanctioned on-device path (the
bundled-font path from Apple's developer page is the restricted one). A
segmented Serif/Sans choice in the settings sheet, persisted as
`reader.typeface`, default **serif** — the printed-spread default.

When a face is chosen, reader.js sets
`html { font-family: <stack> !important }` and forces
`body, p, li, div, h1–h6, blockquote, figcaption, td, th, dd, dt
{ font-family: inherit !important }` (code/pre keep their monospace);
with no choice, publisher fonts stand. Switching re-styles live sections
and re-paginates. macOS never sets a face and is unchanged.

### Next — device pass

Install to a phone, read a real book, tune the fixed paddings if the
running header/footer feel tight.

## Out of scope

macOS chrome, App Store, storage changes, whole-book page counts, making
line height or measure configurable on iOS, bundling font files.
