# macOS Reader Layout Implementation Plan

> **For agentic workers:** Use the executing-plans skill to implement this plan phase by phase. Steps use checkbox syntax. Each phase ends in exactly one commit; keep its tests, implementation, and documentation together.

**Goal:** Make the macOS reader comfortable on the user's 15-inch M5 MacBook Air, with automatic one-page/two-page layout and a remembered manual override.

**Architecture:** Keep one WKWebView and the existing epub.js rendition. macOS owns the persisted layout preference; the web reader resolves the effective layout from the actual available viewport and rendered typography. Reuse the existing navigation and CFI machinery to preserve the visible passage during reflow.

**Tech Stack:** Swift 6.2, SwiftUI, WebKit, Swift Testing, vendored epub.js 0.3.93.

**Spec:** The design contract below is the specification for this plan. The user selected “Automatic one or two pages, with a manual override.” Other sizing and fallback choices are proposed implementation defaults, subject to the acceptance checks below.

## Scope and current evidence

This document is the development plan. The six commits below are implementation work, not completed fixes. Commit each phase during implementation, then push the completed implementation and create its PR. Do not create a PR containing only this plan. Inspection baseline: `3c6919c`.

- `apple/Sources/MarginsModel/Resources/reader/reader.js` hardcodes `spread: "none"`. `readerApplyViewerWidth()` caps the entire viewer at `lineWidthCh`, currently expressed in the outer document's `ch`, not measured from the book's rendered font.
- `readerQueueRelayout()` debounces `rendition.resize()` by 120 ms. It does not explicitly serialize preference changes and anchor restoration with navigation.
- `reader.html` supplies shared padding, including vertical space described for the iOS overlaid controls. macOS has a separate native footer.
- `ReaderView.swift` gives the webview a 400-point minimum and the notes pane 340 points. `ContentView.swift` permits a 720-point window before accounting for the library sidebar. Narrow-window behavior needs direct verification.
- `ReaderPreferences.swift` persists macOS font size, line height, and line width, but no page mode. `ReaderController.swift` observes and forwards those settings.
- `readerReportRelocated()` and `ReaderProgress` retain only the start page, so the footer cannot describe a visible two-page range.
- `docs/architecture.md` documents the shared renderer and the five-resource scheme-handler allowlist. The implementation must preserve that allowlist.

These are code observations, not a claim that the visual defects have been reproduced on the user's hardware.

## Design contract

### Layout and typography

Use a native “Page Layout” picker with **Automatic**, **One Page**, and **Two Pages** in the existing typography popover. Default to Automatic and persist locally under `reader.pageLayout.macos`. Unknown stored values fall back to Automatic. Keep this preference separate from Reset Typography.

- **Automatic:** show two pages only when each page can retain a comfortable measure at the current text size; otherwise show one centered page.
- **One Page:** always show one centered column with the selected maximum line width, even in fullscreen.
- **Two Pages:** prefer two pages, but fall back to one when the minimum readable measure cannot fit. Preserve the requested preference and show “One page shown — widen the window or reduce text size” in the popover while falling back.
- Base decisions on the reading viewport after native sidebar/notes allocation, not display model, chip, physical pixels, or a landscape flag. Use CSS pixels inside WebKit and actual window points for native acceptance measurements; do not assume a screen scaling setting.
- Preserve the current macOS font percentage, line-height range, line-width range, theme, and publisher typeface. Interpret line width as the maximum **per-page** measure. Large text must cause reflow/fallback, never silent font reduction.
- Keep pages on the existing paper surface. Use whitespace for the gutter, without adding page shadows, a book-spine ornament, or iOS glass to the content.

Initial calibration constants: 24 CSS px outer horizontal inset, 40 CSS px inter-page gutter, 24 CSS px top/bottom inset on macOS. Automatic needs at least `min(selectedLineWidthCh, 56)` characters per page; manual Two Pages needs at least 40. Measure a representative body font's zero glyph after applying typography and loading fonts. These are starting values to validate in Phase 1, not measured MacBook Air specifications.

Given viewport width `W`, glyph width `c`, and chosen minimum measure `m`, two pages fit at `W >= 48 + 40 + 2*m*c`. Single-page width is capped at `48 + selectedLineWidthCh*c`; two-page width is capped at `48 + 40 + 2*selectedLineWidthCh*c`. Apply insets and the gutter exactly once, accounting for epub.js's own column geometry. On a very narrow viewport, reduce outer insets before allowing content clipping.

Automatic enters two-page mode 32 CSS px above the fit threshold and leaves below the fit threshold. This hysteresis prevents repeated flips while dragging a divider. Manual Two Pages uses the fit threshold directly. Recompute on viewport, typography, and content-font changes. Observe the available container, not the capped viewer, to prevent resize feedback loops.

Covers and fixed-layout content retain their aspect ratio and publisher layout constraints; do not force reflowable two-column rules onto them. Begin with single-page fallback for fixed-layout content. RTL and vertical writing keep their existing rendering behavior unless the pinned engine is verified to support the proposed spread treatment; unsupported modes fall back to one page.

### Position, progress, and controls

A page turn advances one visible screen: one page in single mode, one spread in double mode. Keep existing keyboard and trackpad bindings. Let epub.js own page ordering and chapter boundaries; do not implement spreads as two independent readers or two consecutive `next()` calls.

Before reflow, capture the latest settled start CFI (EPUB content location), resize the existing rendition, and restore that passage only if no newer user navigation superseded it. After settling, that CFI must remain within the visible location range; identical start CFIs are not required after repagination. A late callback from a previous book must never affect the current book.

Show “Pages 4–5 of 20” for a verified same-section range, “Page 20 of 20” for a single terminal page. Counts remain chapter-local and reflow-dependent. If a spread crosses sections, retain the start-section label instead of inventing a combined total. Keep the start CFI as the persistence anchor. Existing named bookmarks and note storage remain compatible; a bookmark on the second visible page must be recognized as visible.

### Alternatives considered

| Approach | Benefit | Trade-off |
| --- | --- | --- |
| Automatic plus manual override (selected) | Fits fullscreen, windowed reading, and notes use | Requires robust reflow and an effective-layout state |
| Manual one/two pages only | Simpler state model | Makes the user adjust layout after window changes |
| Single page with larger width | Smallest change | Does not solve comfortable use of a wide reading area |

## Global constraints

- One implementation phase equals one commit, using uppercase prefixes without colons.
- macOS deployment target remains 14; iOS remains 26. Use full Xcode 26.x for builds.
- Keep the shared reader and vendored dependency versions; do not add a Node build pipeline or renderer dependency.
- Preserve the five-resource allowlist; put renderer helpers in the existing `reader.js`.
- iOS retains its existing single-page layout and controls. Gate desktop behavior explicitly; do not infer platform from font units.
- Keep annotation/position files and CoreStore API compatible. No database, migration, or stored page-number identity.
- No new keyboard shortcuts are required. If implementation adds one, update both README and `KeyHelp.swift` in that same commit.
- Run `swift test --package-path apple` before every phase commit. Record failures accurately; do not call a failing phase complete.

## Phase 1 — Establish reproducible layout acceptance cases

**Commit:** `CHORE Add macOS reader layout fixtures and baseline checks`

**Files:**
- Create `apple/Tests/MarginsModelTests/Fixtures/reader-layout/` with generated, redistributable EPUB fixtures and a README explaining their construction.
- Modify `apple/Package.swift` to copy that fixture directory into the model test bundle.
- Create `apple/Tests/MarginsModelTests/ReaderLayoutIntegrationTests.swift`.
- Create `docs/testing/macos-reader-layout.md`.

- [ ] Add a reflowable fixture with uniquely identified paragraphs, multiple spine sections, an odd final page, a chapter fragment link, a large image, and publisher typography. Add small RTL and fixed-layout fixtures to exercise safe fallback.
- [ ] Build a macOS-only WKWebView test harness using the existing ReaderSchemeHandler and an isolated temporary library. Load the actual bundled renderer and wait for reader messages, with bounded timeouts and captured errors. No arbitrary sleeps or private library paths.
- [ ] Assert current book opening, CFI navigation, next/previous, and relocation with the fixture. Baseline tests must pass on current behavior; record the missing two-page behavior in the manual checklist rather than committing a failing test suite.
- [ ] Capture one-page baselines at content viewports 600×650, 900×700, 1200×760, and 1440×820 CSS px. These are test dimensions, not claimed hardware resolutions. Include notes/sidebar open and closed in native screenshots.
- [ ] Audit the pinned epub.js implementation for `spread`, `resize`, rendered/relocated ordering, fixed-layout behavior, and start/end locations. Record the supported calls and event sequence in the testing document before Phase 2 relies on them.
- [ ] Run the suite and `make app`; record screenshots and actual available viewport size on the target MacBook Air if available. If unavailable, label hardware acceptance pending and continue with reproducible WKWebView cases.
- [ ] Commit the passing fixture/harness and baseline documentation together.

**Gate:** Deterministic book navigation works in the harness, with measured baseline geometry and an explicit engine integration contract.

## Phase 2 — Implement width-aware single and double pagination

**Commit:** `FEAT Add adaptive macOS reader pagination`

**Files:** Modify `reader.js`, `reader.html`, and `ReaderLayoutIntegrationTests.swift` at the paths above; modify `apple/Sources/Margins/Reader/ReaderController.swift`.

**Interfaces:** Introduce `window.readerSetPageLayout(mode)` accepting `automatic`, `single`, or `double`. It stores calls received before opening. A macOS-specific URL parameter `platform=macos` opts into desktop spacing and layout; absent/unknown values retain existing behavior. Phase 2's native bridge sends `automatic` on page load; Phase 3 replaces that literal with the preference.

- [ ] Add failing WKWebView cases: narrow Automatic produces one column; wide Automatic produces two; One Page remains single; Two Pages falls back when narrow; a larger body font can trigger fallback. Assert real rendition geometry and visible text, not only a mode string.
- [ ] Add pure layout resolution inside the existing JS file. Use this contract for numeric policy cases:

```javascript
// resolveReaderLayout({mode, widthPx, glyphWidthPx, lineWidthCh,
//                      previousPages}) -> {pages, viewerWidthPx}
// With glyphWidthPx=8, lineWidthCh=72:
// automatic, previousPages=1, widthPx=1016 => pages=2
// automatic, previousPages=2, widthPx=983  => pages=1
// single, widthPx=1400 => pages=1
// double, widthPx=728  => pages=2
// double, widthPx=727  => pages=1
```

- [ ] Implement that policy, body-font measurement, platform-gated spacing, and rendition spread updates using Phase 1's verified engine calls. Keep the original iOS path intact. Measure again after section fonts load.
- [ ] Observe the uncapped viewport with ResizeObserver and coalesce updates through the existing relayout scheduler. Skip identical geometry. Disconnect observers and clear timers when the page unloads.
- [ ] Validate covers/fixed-layout and unverified writing modes take the single-page fallback. Test next/previous across an odd final page and a chapter boundary for omitted or duplicated paragraphs.
- [ ] Run the suite and `make ios-build`; visually compare the iOS fixture with baseline. Commit only once both desktop geometry and iOS preservation checks pass.

**Gate:** Automatic responds to actual available width, and the existing page-turn command traverses every fixture paragraph in order.

## Phase 3 — Expose and persist native page-layout controls

**Commit:** `FEAT Add macOS page layout preferences`

**Files:** Modify `ReaderPreferences.swift`, `ReaderPreferencesTests.swift`, `ReaderController.swift`, `TypographyPopover.swift`, and `ReaderView.swift` in their existing directories.

**Interfaces:** Add macOS-only `ReaderPageLayout: String, CaseIterable, Sendable` with `automatic`, `single`, `double`; expose `ReaderPreferences.pageLayout`. Add JS message `{type: "layoutChanged", requested: string, pages: 1|2}`. Keep effective state transient on `ReaderModel` as `effectivePageCount: Int?`, reset when opening/closing a book; also modify `ReaderModel.swift` and `ReaderModelTests.swift` for this state.

- [ ] Add preference tests before implementation: default Automatic, each value round-trips through an isolated defaults suite, unknown value falls back, and `resetTypography()` preserves page-layout choice. Example assertion:

```swift
let preferences = ReaderPreferences(defaults: defaults)
#expect(preferences.pageLayout == .automatic)
preferences.pageLayout = .double
#expect(ReaderPreferences(defaults: defaults).pageLayout == .double)
preferences.resetTypography()
#expect(preferences.pageLayout == .double)
```

- [ ] Implement the enum, persistence key, and observation. Send the mode with JSON-safe serialization on initial load and every change, including changes made while the book is opening.
- [ ] Add the labeled three-option picker in TypographyPopover and pass effective page count from ReaderView. Only show the fallback explanation when Two Pages is selected and one page is actually rendered; do not claim fallback while loading.
- [ ] Validate incoming layout messages before updating transient state. Reset effective state when the book changes so a stale fallback message cannot remain in the UI.
- [ ] Check keyboard focus, VoiceOver labels, preference restoration on relaunch, and unchanged text-size shortcuts. Run the suite and `make app`, then commit.

**Gate:** The user can select all three modes, observe fallback, and recover their requested mode by widening the window without changing the preference again.

## Phase 4 — Preserve the reading passage through reflow

**Commit:** `BUG Preserve reading position during layout changes`

**Files:** Modify `reader.js`, `ReaderController.swift`, `ReaderLayoutIntegrationTests.swift`; extend `ReaderModelTests.swift` only where model behavior changes.

- [ ] Write failing integration cases that save a middle-of-chapter CFI, change mode/font/viewport, and verify the saved CFI remains visible after settlement. Repeat with rapid alternating widths and a navigation request during reflow.
- [ ] Serialize layout transactions using the existing `readerNavigationToken` plus a layout generation. Capture a settled CFI, coalesce geometry updates, resize, await engine settlement, and re-anchor only when both generations still match. Drop outdated work on navigation, book replacement, or teardown.
- [ ] Prevent provisional relocation events from overwriting the stable saved anchor during a layout transaction. Publish final progress after settlement; a new user navigation must always win over an old re-anchor.
- [ ] On a failed re-anchor, retain the last settled model position and surface the existing reader error path if the rendition is unusable. Avoid an unbounded display/resize retry loop. Retain the existing stale-CFI chapter fallback for opening a book.
- [ ] Exercise rapid notes-pane animation, continuous window resizing, text-size changes, fullscreen transitions, chapter jumps, close/reopen, and switching books during reflow. Assert no duplicate webview, no blank settled page, and no late jump to a previous book.
- [ ] Run the suite and `make app`; commit the race fixes and their regression tests together.

**Gate:** Resizing and preferences retain the visible passage; navigation during a resize lands at the newly requested target.

## Phase 5 — Make progress and bookmarks understand visible spreads

**Commit:** `FEAT Show spread-aware reading progress`

**Files:** Modify `reader.js`, `ReaderModel.swift`, `ReaderController.swift`, `ReaderFooter.swift`, `ReaderModelTests.swift`, `ReaderLayoutIntegrationTests.swift`; inspect `apple/ios/Margins/Reader/ReaderBridge.swift` for compatibility. Extend `apple/Sources/MarginsModel/LibraryModel.swift` and its bookmark tests only if its existing matching path needs the new visible range.

**Interfaces:** Extend relocation messages with optional `endPage`, `endHref`, and `endCfi` from the engine. Add defaulted `endPage: Int? = nil` to `ReaderProgress.init(page:totalPages:endPage:)`. Extend `ReaderModel.relocated(page:totalPages:href:cfi:endPage:endHref:endCfi:)` with nil defaults for the three new trailing arguments so existing iOS callers compile unchanged. Keep end CFI/href transient; do not change stored position/bookmark schemas.

- [ ] Add tests for same-section 4–5 of 20, single terminal page, invalid/reversed endpoint, missing endpoint, and cross-section spread. Accept a range only when both endpoints refer to the same resolved spine section and `page <= endPage <= totalPages`.
- [ ] Forward actual engine endpoints; do not synthesize `page + 1`. Render a range only when the accepted end page exceeds the start. Preserve start-section progress semantics for cross-section spreads and existing iOS calls.
- [ ] Check existing bookmark matching against visible start/end CFIs using the existing CFI utilities. Add a regression test for a bookmark visible on the second page. Retain start-CFI semantics for “Bookmark This Page” and check toggling layout does not create duplicate bookmarks.
- [ ] Validate chapter labels, book percentage, bookmark resume, chapter notes, and reading-position saves across chapter boundaries. Persist content locations, never the new visual page range.
- [ ] Run the suite, `make app`, and `make ios-build`; commit.

**Gate:** Footer and bookmark affordance describe what is visible without changing stored anchors or breaking iOS callers.

## Phase 6 — Calibrate the MacBook Air experience and document behavior

**Commit:** `BUG Refine macOS reader spacing across window sizes`

**Files:** Modify `ReaderView.swift`, `apple/Sources/Margins/ContentView.swift`, `reader.html`, and layout constants in `reader.js` only as acceptance findings require; update `README.md`, `docs/architecture.md`, and `docs/testing/macos-reader-layout.md`.

- [ ] Run the matrix below on the 15-inch M5 MacBook Air. Record macOS version, selected display scaling, window dimensions, WKWebView viewport, mode, text size, and screenshots. Physical hardware acceptance must be explicitly pending if that machine is unavailable; passing synthetic viewports does not replace it.
- [ ] Adjust the Phase 2 spacing/fit constants only from observed readability and clipping results; update numeric policy tests with any approved calibration. Check default 110% and extremes 70%/200%, widths 50/72/110 ch, and light/dark themes.
- [ ] Resolve the 400 + 340 minimum-width pressure at a 720-point window. When both panes cannot fit, prefer a single reading column and make notes presentation fit the available native window without hidden controls or silent loss of note edits. Keep the notes editor usable at its existing 320-point minimum; increase the combined native minimum while notes are shown if necessary, and document the resulting minimum with sidebar open and closed.
- [ ] Verify the native footer replaces unnecessary iOS overlay padding on macOS; check top/bottom text clipping, image aspect ratio, readable gutter, and long chapter-title truncation.
- [ ] Document layout modes, fallback, local preference persistence, chapter-local page ranges, and the revised renderer contract. If no corrective spacing code is needed, use `DOCS Document macOS reader layout acceptance` as this phase's single commit instead.
- [ ] Run `swift test --package-path apple`, `make app`, and `make ios-build`. Complete the visual/accessibility matrix and record results before committing.

| Scenario | Required result |
| --- | --- |
| Air fullscreen, default text, notes/sidebar closed | Automatic chooses two readable columns if measured threshold fits; balanced outer margins |
| Air normal window and half-screen window | Mode follows actual width; One Page remains centered; no clipping |
| Notes/sidebar opened and closed repeatedly | Effective layout adapts; current passage and unsaved notes survive |
| Large text and low-height window | No forced font reduction or footer overlap; fallback behaves as documented |
| Single/two-page override, close/relaunch | Requested choice persists; effective layout still respects available space |
| Chapter start/end, odd page count, images, links | No missing paragraphs, duplicate turns, stretched images, or broken links |
| Keyboard, trackpad, VoiceOver | One command turns one visible screen; controls have usable labels/focus |
| iPhone and iPad, narrow/wide sizes | Existing single-page layout, controls, selection, and highlights remain usable |

**Gate:** All reproducible checks pass. Release acceptance includes the target-machine matrix, with any unavailable hardware check disclosed rather than marked complete.

## Commit and PR workflow for implementation

1. Execute phases in order, checking their boxes only after verification. Make exactly one commit per phase with the listed prefix format; include fixes to that phase before committing.
2. Before push, review `git diff --check`, `git status --short`, and the six-commit diff against the implementation base. Ensure no fixture includes personal books, notes, or machine-specific paths.
3. Push the implementation branch with `git push -u origin HEAD` and create a PR. Title: `FEAT Add adaptive macOS reader page layouts`.
4. PR description: explain Automatic/One Page/Two Pages, narrow-window fallback, CFI preservation, and page-range behavior. Include test/build results and paired single/spread screenshots, plus exact hardware verification status.
5. Do not merge automatically. The PR must contain the implemented reader changes and their validation, not just this development plan.
