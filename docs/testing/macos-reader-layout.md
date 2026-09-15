# Testing the macOS reader layout

This document is the acceptance record for the adaptive macOS reader
layout work and the engine contract the implementation is allowed to rely
on. It is updated as each phase lands; the phase plan lives in
`docs/macos-reader-layout-plan.md`.

## Harness

`ReaderLayoutIntegrationTests` drives the real reader page
(`MarginsModel`'s vendored `reader.html` + `reader.js` + epub.js 0.3.93) in
an offscreen `WKWebView`:

- Fixtures are committed under
  `apple/Tests/MarginsModelTests/Fixtures/reader-layout/` and served
  through the production `ReaderSchemeHandler`; the bytes provider returns
  the fixture directly, so no library on disk is touched.
- Every wait is async and bounded (`ReaderLayoutHarness`); the suite
  never sleeps arbitrarily.
- The harness injects a test-only document-start script that
  (a) forwards `console` output and uncaught errors as `console`
  messages, and (b) replaces `requestAnimationFrame` with a timer-backed
  shim. WebKit suspends rAF entirely in a hidden page, and epub.js routes
  its rendition queue, relayout and relocation reporting through rAF; the
  shim is what lets the engine run without an on-screen window. This is
  test scaffolding only — production reader code is untouched.
- Geometry is reported by the harness's `__marginsTest` helpers
  (`geometry()`, `visibleParagraphIDs()`), which read the rendition's
  layout and the section iframes. They are not part of `reader.js`.

`swift test --package-path apple` runs the suite; it is macOS-only
(`#if os(macOS)`) and serialized because each case starts a WebKit content
process.

## Pinned engine contract (epub.js 0.3.93)

Audited in the vendored `epub.min.js` before Phase 2 relied on it:

- **Layout**: `Layout.calculate(width, height, gap)` picks
  `divisor = spread && width >= minSpreadWidth ? 2 : 1`. With divisor 2,
  `columnWidth = width / 2 - gap`, `pageWidth = width / 2`,
  `delta = width`; with divisor 1, `columnWidth = width` and `delta = width`.
  For reflowable paginated content, when `gap` is not passed the layout
  uses `even(floor(width / 12))` as its own gutter. The rendition-level
  `gap` setting is only honoured by the engine when it is exactly `0`, so
  a fixed gutter must be applied by calling `calculate(width, height,
  gutter)` consistently (Phase 2 wraps the layout instance, scoped to the
  macOS platform and single initialized renditions).
- **Spread**: `rendition.spread(spread, minSpreadWidth)` mutates
  `settings.spread`, updates the layout instance (`_spread`,
  `_minSpreadWidth`) and calls `manager.updateLayout()`. It does not
  re-display by itself.
- **Resize**: `rendition.resize()` asks the manager to re-measure. If the
  stage's size is unchanged, the manager returns without emitting
  `RESIZED`; a width change must reach the stage first (the reader
  changes `#viewer`'s box and then calls `resize()`).
- **Re-layout path**: manager `RESIZED` → `rendition.onResized` → emit
  `resized` → `display(location.start.cfi)` when a location is known →
  `reportLocation()` → `relocated`. Reporting runs through the rendition
  queue and `requestAnimationFrame`.
- **Locations**: `currentLocation()`/`located()` returns
  `start`/`end` where each carries `index`, `href`, `cfi`, and
  `displayed: { page, totalPages }`. `start.displayed` comes from the
  first visible view and `end.displayed` from the last, so with a spread
  they are per-section page numbers for the left and right page. A
  cross-section spread therefore reports different `start.href` and
  `end.href`.
- **Page turns**: `next()`/`prev()` advance `delta` (one visible screen:
  one column in single mode, one spread in double mode) and then report
  location. Chapter order and boundaries stay entirely inside the engine.
- **Fixed layout**: when the package metadata is
  `rendition:layout = pre-paginated`, the rendition forces
  `settings.layout = "pre-paginated"`; `calculate` then zeroes the gutter
  and, with a divisor of 2, sets `width = columnWidth`. A package
  `rendition:spread` of `none` forces `settings.spread = "none"`.
- **Events**: `rendered` fires per rendered view; `relocated` fires after
  displays, page turns, and completed re-layouts. The page reports both
  through the `reader` message handler.

## Baseline (Phase 1, `spread: "none"`, 110 % / 1.6 / 72 ch)

Measured by the harness on macOS 26 (MacBook Air M5, Mac17,4) with the
app's default macOS typography applied. The viewer is capped at 576 px —
72 `ch` in the *outer document's* 16 px fallback font (8 px/ch), which is
the defect the plan calls out: the cap is unrelated to the book's rendered
font. Stage = viewer minus the reader.html padding (44.8 px horizontal,
67.2 px vertical).

| Viewport (CSS px) | Viewer | Stage | Divisor (pages) | Iframes |
| --- | --- | --- | --- | --- |
| 600 × 650 | 576 × 650 | 531 × 583 | 1 | 1 |
| 900 × 700 | 576 × 700 | 531 × 633 | 1 | 1 |
| 1200 × 760 | 576 × 760 | 531 × 693 | 1 | 1 |
| 1440 × 820 | 576 × 820 | 531 × 753 | 1 | 1 |

Covered by `onePageBaselines(width:height:)`, which also asserts no
horizontal clipping.

## Manual checklist

| Item | Status |
| --- | --- |
| Deterministic open, CFI navigation, next/prev with fixtures | automated (passing) |
| One-page geometry at 600/900/1200/1440 CSS px | automated (passing) |
| Two-page behavior | absent by design until Phase 2 |
| Native window with notes/sidebar open and closed | Phase 6 (hardware: MacBook Air M5, Mac17,4 available) |
| Fullscreen, large text, theme extremes | Phase 6 |
| iPhone/iPad single-page preservation | Phase 6 (`make ios-build` + simulator) |
