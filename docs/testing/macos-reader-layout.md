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

## Desktop policy (Phase 2)

The page opts into desktop behavior through the URL (`platform=macos`, sent
only by the macOS bridge). iOS never sets it and retains the original
`spread: "none"` full-width column.

- `window.readerSetPageLayout(mode)` accepts `automatic` (default),
  `single`, or `double` and stores the value if it arrives before the book
  opens. Unknown values resolve to Automatic.
- The effective mode is downgraded to `single` for content the pinned
  engine's spread treatment is not verified for: fixed-layout packages
  (`rendition:layout = pre-paginated`), `page-progression-direction=rtl`,
  and vertical writing modes.
- `window.readerResolveLayout({mode, widthPx, glyphWidthPx, lineWidthCh,
  previousPages})` is the pure policy. With `glyphWidthPx = 8`,
  `lineWidthCh = 72`: `automatic,previousPages=1,width=1016 => 2`;
  `automatic,previousPages=2,width=983 => 1`; `single => 1`;
  `double,width=728 => 2`; `double,width=727 => 1`. The viewer cap is
  `48 + lineWidthCh * glyph` for one page and `48 + 40 + 2 * lineWidthCh *
  glyph` for two, where 48 is the total outer inset and 40 the gutter.
- Automatic enters two pages 32 CSS px above the fit threshold and leaves
  below the threshold; Two Pages uses the fit threshold directly. The fit
  width is `48 + 40 + 2 * min(lineWidthCh, 56) * glyph` for Automatic and
  `48 + 40 + 2 * 40 * glyph` for Two Pages.
- The glyph width is measured with canvas `measureText("0")` against the
  rendered section's body font (matching CSS `ch`), re-measured after
  re-styling and `document.fonts.ready`. Before any section renders the
  page uses half the requested em.
- `#viewer` is wrapped in an uncapped `#page` container; a
  `ResizeObserver` on `#page` (never on the capped viewer) coalesces to one
  resolution per animation frame. Identical geometry is skipped.
- The gutter is passed to epub.js at rendition creation (`gap: 40`). Its
  `Contents.columns()` then applies `gap/2` horizontal body padding on
  each side *and* a `column-gap` of `gap`, so the rendered measure is
  `(stageWidth - 80) / 2` per page rather than the `(stageWidth - 40) / 2`
  a hand-rolled gutter would give. At the cap this reads ~2 characters
  below `lineWidthCh`; the outer margins and the inter-page whitespace are
  symmetric, which the paired screenshot check confirms. Phase 6 revisits
  this if readability at the extremes disagrees.

Phase 2 measures (MacBook Air M5, macOS 26): at 1400 CSS px Automatic
renders two columns with a 40 px gutter and 24 px outer insets; at 600 px
it renders one. Two Pages falls back to one at 600 px and succeeds at
1000 px; 200 % text forces Automatic back to one page at 1440 px. Fixed
layout and RTL stay single at every width. iPhone 17 Pro simulator: the
fixture renders as a full-width single column with the iOS CSS padding
(22.4 px), identically to the Phase 1 baseline.

## Acceptance matrix (Phase 6)

Target machine: **15-inch MacBook Air M5 (Mac17,4)**, macOS 26.5.2,
logical resolution 1920 × 1243 points at scale 2 (visible 1920 × 1205).
Measured with the app's default typography (110 % / 1.6 / line width as
noted). "Measure" is the text width of a full page. These viewports are
the reading surface after native chrome and footer, so they stand in for
window sizes: fullscreen ≈ 1920 × 1123, a normal window ≈ 1100 × 800,
half-screen ≈ 720 × 800, and the reader with the notes pane open at a
1100-point window ≈ 740 × 800.

| Viewport | Text | Line width | Pages | Viewer | Stage | Measure |
| --- | --- | --- | --- | --- | --- | --- |
| 1920 × 1123 | 110 % | 72 ch | 2 | 1644 | 1596 | 756 (70 ch) |
| 1100 × 800 | 110 % | 72 ch | 1 | 826 | 778 | 724 (67 ch) |
| 720 × 800 | 110 % | 72 ch | 1 | 720 | 672 | 624 (58 ch) |
| 740 × 800 | 110 % | 72 ch | 1 | 740 | 692 | 624 |
| 1100 × 800 | 200 % | 72 ch | 1 | 1100 | 1052 | 982 |
| 1100 × 800 | 70 % | 72 ch | 2 | 1078 | 1030 | 460 |
| 1100 × 800 | 110 % | 50 ch | 1 | 588 | 540 | 486 |
| 1100 × 800 | 110 % | 110 ch | 1 | 1100 | 1052 | 1011 |
| 1100 × 500 | 110 % | 72 ch | 1 | 826 | 778 | 723 |
| 1920 × 1123 (dark) | 110 % | 72 ch | 2 | 1644 | 1596 | 756 |

Observed calibration notes:

- The measure runs a few characters under the selected line width
  because epub.js's `Contents.columns()` spends `gap/2` horizontal body
  padding on each page in addition to the column gap. At the two-page cap
  the measure is 70 ch for a 72 ch setting; single-page is ~67 ch
  (epub.js spends the full 40 px on one page). The setting is a maximum
  the layout stays under, so no constant change is warranted from these
  readings; the gutter and outer margins are symmetric and the pages stay
  balanced (verified in the paired single/spread screenshots).
- **Bug found and fixed in this phase:** the glyph width measured before
  any section rendered (half an em of the outer document's fallback font,
  8.8 px) was cached against the typography revision, so the reader kept
  that estimate for the whole session and only re-measured after a
  typography change. The book's actual Georgia digit is 10.8 px; the
  cache key now includes a contents revision bumped when a section
  renders. The matrix above is measured with the real glyph.
- Fixed-layout and RTL fixtures stay single-page at every width, and the
  iOS page keeps its full-width column (iPhone 17 Pro and iPad Pro 13-inch
  M5 simulator screenshots, `make ios-build` passing).

Native pane minimums: the reader webview keeps its 400-point minimum and
the notes editor its 320-point minimum (growing to 460 on wide windows).
While the notes pane is shown the window minimum rises to 960 points
(reader + editor + the library sidebar) so nothing clips and no control
hides; with the notes pane closed the window minimum stays 720. The
macOS page uses 24 px top/bottom insets instead of the iOS overlay
padding, so text clears the native footer; long chapter titles truncate
in the footer with a tooltip.

Hardware status: the matrix above is reproducible WKWebView acceptance at
the target machine's logical window sizes, and the ad-hoc `make app`
build was installed and exercised natively on the target machine:

- Measured/verified in the installed app: library load from the iCloud
  container, two-page spread at a wide window, the Page Layout picker in
  the typography popover, the Two Pages fallback note at a narrow window,
  recovery to two pages by widening without touching the preference, and
  the footer reading "Pages 1–2 of 2".
- Still to spot-check natively: notes pane open/closed during reflow,
  fullscreen transitions, VoiceOver order, and long-running resume.

The earlier crash-on-launch of the ad-hoc build was a real bug: on macOS
`FileManager.default.ubiquityIdentityToken` is non-nil even for a bundle
with no entitlements, so `ClubSync.automatic` never took its documented
local-engine fallback and `CKContainer(identifier:)` trapped. `ClubSync`
now checks the iCloud container entitlement (`SecTaskCopyValueForEntitlement`,
macOS only) before choosing the transport, so unsigned and ad-hoc builds use
the local engine while signed builds keep CloudKit.

## Spread-aware progress (Phase 5)

- Relocation messages now carry the engine's own `endPage`, `endHref`,
  and `endCfi` (from `location.end`), never a synthesized `page + 1`.
- `ReaderProgress.endPage` is set only when both endpoints resolve to the
  same section and `page <= endPage <= totalPages`. Reversed,
  out-of-range, missing, and cross-section endpoints stay nil, leaving
  start-section progress in charge.
- The footer shows "Pages 4–5 of 20" for an accepted range and "Page 20
  of 20" otherwise. The persisted anchor is still the start CFI: nothing
  about the visible range is stored, and `ReadingPosition`, `Bookmark`,
  and the iOS caller signature are unchanged (the new trailing arguments
  default to nil).
- `pageIsBookmarked` also matches the verified second page's start CFI, so
  a pin dropped before a layout change still reads as the current page
  after that page becomes the right side of a spread. A nil end CFI never
  matches, preserving the existing "CFI-less pin stops matching once the
  renderer reports a CFI" behavior.

Covered by the `ReaderModel` range tests (4–5 of 20, terminal page,
reversed, out-of-range, missing, cross-section) and the integration
endpoint tests (spread `endPage == page + 1` with a distinct end CFI;
single page reports its own page).

## Reflow transactions (Phase 4)

Every desktop geometry change (viewport, typography, page mode) runs as
one transaction:

- `readerQueueRelayout` coalesces bursts (120 ms) and records a layout
  generation plus the navigation token. The anchor is read when the
  transaction *starts*, not when it is scheduled: a schedule can span a
  navigation, and a pre-navigation anchor would drag the reader back.
- The anchor is the last settled page start. Relocations update it only
  when they are trusted: never mid-transaction, and not while geometry
  work is queued, because the engine re-displays on its own window-resize
  handler and those locations belong to the layout being replaced. A
  navigation that has resolved is always trusted (it is the page on
  screen), and navigation drops the old anchor outright.
- A transaction waits out in-flight navigations (bounded), calls
  `rendition.resize()`, waits for the rendition queue to drain (bounded at
  500 ms) and then, only if the generation and token still match,
  re-anchors once with `display(anchor)`. There is no retry loop; a failed
  re-anchor keeps the last settled position and logs through the console.
- Relocation reports are withheld for the whole transaction, so the shell
  never sees a half-relaid-out page; the transaction publishes the settled
  location once at the end. A user page turn or jump during the
  transaction bumps the token, so the re-anchor is abandoned and the
  user's destination wins.
- `pagehide`/`unload` bump the generation and clear the in-flight state,
  so a torn-down page cannot finish a transaction.

Covered by `textSizeChangeKeepsPassage`, `modeChangeKeepsPassage`,
`rapidResizesKeepPassage`, `navigationDuringReflowWins`, and
`reflowLeavesOneVisibleView` (single visible iframe, no blank page, no
error page).

## Native controls (Phase 3)

- `ReaderPageLayout` (`automatic` / `single` / `double`) persists under
  `reader.pageLayout.macos`; unknown stored values load as Automatic, and
  `resetTypography()` deliberately leaves it alone.
- The typography popover adds a labeled, segmented three-option picker.
  The fallback line ("One page shown — widen the window or reduce text
  size") renders only when Two Pages is selected *and* the renderer has
  reported one page; while the book is loading `effectivePageCount` is
  nil, so no fallback is claimed.
- The page posts `{type: "layoutChanged", requested, pages}` after every
  applied resolution once the book is open. `ReaderModel.layoutChanged`
  drops payloads whose requested mode is unknown or whose page count is
  not 1 or 2, and `open`/`close` clear the transient count so a stale
  message cannot outlive its book.
- `make app` produces an ad-hoc signed bundle; on a machine with an iCloud
  account this build traps at `CKContainer(identifier:)` (no CloudKit
  entitlement) before any window appears — a pre-existing limitation of
  the ad-hoc build, not of the reader. The native popover screenshot is
  therefore in the Phase 6 matrix, to be taken from a signed build.

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
| One-page geometry at 600/900/1200/1440 CSS px | superseded by the adaptive cases in Phase 2 |
| Adaptive single/two-page policy, fallback, hysteresis, large text | automated (passing) |
| Pure policy numeric contract | automated (passing) |
| Page turns cover every fixture paragraph in order | automated (passing) |
| Fixed-layout and RTL single-page fallback | automated (passing) |
| iOS single-page preservation | automated + iPhone 17 Pro simulator screenshot |
| Requested/effective layout messages and popover fallback state | automated (passing) |
| Passage preserved through text-size, mode, and rapid width changes | automated (passing) |
| Navigation during reflow wins; no blank/duplicate views | automated (passing) |
| Preference round-trip on relaunch | automated (UserDefaults round-trip) |
| Window-sized matrix, text sizes, line widths, themes | automated (`Reader layout matrix`, passing) |
| Native window with notes/sidebar open and closed | launch, layout, picker, and fallback verified on hardware; notes-pane and VoiceOver spot-checks remain |
| Fullscreen, large text, theme extremes | automated at target logical sizes + snapshots |
| iPhone/iPad, narrow/wide sizes | simulator screenshots; `make ios-build` passing |
