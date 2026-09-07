# iOS bug-fix plan (branch `t3code/ios-app`)

Audience: the opencode agent (glm 5.3 flash) with skills installed at
`/Users/zariski/.config/opencode/skill`. This plan was produced by a bug hunt
over the three iOS commits (`79d14e1`, `924ab4e`, `c40e682`) plus the shared
`apple/Sources/MarginsModel` code they lean on. Each finding below lists the
evidence, the fix, how to verify it, and **which skill to invoke**.

## Ground rules

- Read `AGENTS.md`, `docs/architecture.md`, `docs/ios-plan.md` first.
- Available skills and when to use them in this plan:
  - **`diagnosing-bugs`** — invoke BEFORE touching any bug tagged
    `[VERIFY-FIRST]`. Those are code-analysis findings whose runtime failure
    has not been reproduced; the skill's "build a feedback loop first"
    discipline is exactly what they need. Do not "fix" them blind.
  - **`tdd`** — invoke for any fix tagged `[TDD]`: those live at a testable
    seam in `MarginsModel` and must land red → green in
    `apple/Sources/MarginsTests` (runner: `make core && swift run
    --package-path apple MarginsTests`).
  - **`swiftui-pro`** — invoke once before starting Phase 2 (the navigation
    restructure) and again as a review pass after each phase that edits
    SwiftUI files, per that skill's checklist (navigation, data flow,
    performance, accessibility). It is a review skill: run it over the files
    you changed, not the whole repo.
  - **`code-review`** — invoke exactly once, at the very end (Phase 5), with
    fixed point `c40e682`. If `docs/agents/issue-tracker.md` is missing, run
    only the Standards axis and say so (do not run `setup-matt-pocock-skills`
    unprompted).
  - **Do not use** `prototype`, `domain-modeling`, `codebase-design`,
    `improve-codebase-architecture`, `grilling`/`grill-me`/`grill-with-docs`,
    or `setup-matt-pocock-skills` for this work — this is bug fixing, not
    design, and the user is not available for interviews.

## Build & verify loop

- Shared-model tests: `make core && swift run --package-path apple MarginsTests`
  (macOS package; `MarginsModel` is shared, so regressions here break both apps).
- iOS FFI slices: `make ios-core` (only needed if the xcframework is stale).
- iOS app build: `xcodebuild -project apple/ios/Margins.xcodeproj -scheme
  Margins -destination 'platform=iOS Simulator,name=iPhone 16' build` — or use
  the `xcodebuildmcp` MCP server configured in `opencode.json` (preferred for
  builds, simulator boot, launch). Note **CI never builds the iOS app** (only
  the xcframework), so a clean `git status` proves nothing about compilability.
- Simulator repro seams (DEBUG-only env vars, no UI automation needed):
  `MARGINS_IMPORT_FIXTURE=$PWD/fixtures/dostoyevsky_the_karamazov_brothers.epub`,
  `MARGINS_OPEN_FIXTURE=1|reader|notes`, `MARGINS_SEARCH_FIXTURE=<query>`,
  `MARGINS_DELETE_FIXTURE=prompt|confirm`, `MARGINS_CAPTURE_FIXTURE=<text>`,
  `MARGINS_HIGHLIGHT_FIXTURE=1`, `MARGINS_EDITOR_FIXTURE=1`.
- iPad-specific bugs: use an iPad simulator destination (regular size class
  takes the `NavigationSplitView` code path in `LibraryScene`).

---

## Phase 1 — confirmed logic bugs (small, independent fixes)

### 1.1 Hardware keys turn two pages per key press  — HIGH
`apple/ios/Margins/Reader/ReaderBridge.swift:19-27`. `KeyHandlingWebView`
runs the same `handle(_:)` (which calls `onKey` → page turn) from **both**
`pressesBegan` and `pressesEnded`. A single arrow/space press fires key-down
and key-up, so every press pages twice.
**Fix:** only act in `pressesBegan`; in `pressesEnded`, swallow the same keys
without invoking `onKey` (so the web view still doesn't see them).
**Verify:** iPad simulator with hardware-keyboard connected (⇧⌘K), open the
reader, press → once, confirm the page counter advances by exactly 1.

### 1.2 Note-search results use a non-unique `ForEach` id — HIGH
`apple/ios/Margins/LibraryScene.swift:214`: `ForEach(hits, id: \.bookId)`.
`NoteSearchHit` yields one hit per chapter, so two hits from the same book
collide → SwiftUI duplicate-ID undefined behavior (rows render wrong/missing).
`NoteSearchHit` is already `Identifiable` (`bookId/chapterKey`,
`apple/Sources/MarginsModel/Conformances.swift:20-22`).
**Fix:** drop the explicit `id:` and use the conformance.
**Verify:** `MARGINS_SEARCH_FIXTURE` with a query matching notes in two
chapters of one book; both rows must appear, no runtime warning in the log.

### 1.3 "Clear All Notes" leaves the cleared notes on screen — HIGH `[TDD]`
`apple/ios/Margins/BookDetailView.swift:302-304`: the destructive button runs
`library.clearNotes(bookId:)` only. `LibraryModel.clearNotes` does not
recompile (`refresh()` keeps `compiledNotes` when the bookId still matches,
`apple/Sources/MarginsModel/LibraryModel.swift:80-84`), so the Notes tab keeps
showing every deleted note until you navigate away. macOS already does it
right: `apple/Sources/Margins/NotesPageView.swift:304-310` reloads after
clearing.
**Fix (tdd skill):** move the invariant into the model — make
`LibraryModel.clearNotes` refresh `compiledNotes` itself when
`compiledNotes?.bookId == bookId` (write the failing test in
`LibraryModelTests` first: clear → `compiledNotes` reflects zero chapters).
Then simplify the macOS call site to match. Also reset the iOS `NotesTab`
`exportMarkdown` cache (see 3.3) so a stale export can't be shared.
**Verify:** model test green; simulator `MARGINS_OPEN_FIXTURE=notes`, clear
all, tab shows the empty state immediately.

### 1.4 iPad detail pane never loads the reading position — HIGH
`apple/ios/Margins/BookDetailView.swift:33` guards all loading behind
`.task(id: bookID)`, but on iPad the detail is created as `BookDetailView()`
with `bookID == nil` (`LibraryScene.swift:26`), so the task runs once with no
selection and never again. Result: `position` stays nil for every book —
"Continue reading" always reads "Start reading", and the bookmark row marker
never shows; switching books in the sidebar can also never refresh it.
**Fix:** re-run position loading when the effective book changes, e.g.
`.task(id: bookID ?? library.selectedBookID)` (or a second
`.onChange(of: library.selectedBookID)`), keeping the existing iPhone path
intact.
**Verify:** iPad simulator, read a few pages, return, reselect the book from
the sidebar → label says "Continue reading" and the bookmark shows on the
current chapter.

### 1.5 Files-app exposure keys are in the wrong place in Info.plist — MEDIUM
`apple/ios/Info.plist:27-32`: `NSUbiquitousContainerIsDocumentScopePublic`,
`NSUbiquitousContainerName`, and `NSUbiquitousContainerSupportedFolderLevels`
sit at the top level. Apple requires them nested under
`NSUbiquitousContainers` → `iCloud.io.github.nathanstefanik.margins` → dict.
As written they are ignored and the library folder will not appear in the
Files app (a stated goal in `docs/ios-plan.md`).
**Fix:** restructure into the nested dict.
**Verify:** structural only for now — full verification is blocked on the
Apple Developer approval noted in `docs/ios-plan.md`; say so in the commit.

## Phase 2 — iPad navigation restructure

Invoke **`swiftui-pro`** before starting this phase (its navigation reference
covers exactly this), and **`diagnosing-bugs`** to set up the repro first.

### 2.1 `[VERIFY-FIRST]` Reader likely unreachable on iPad — HIGH
`LibraryScene.swift:23-27` puts `BookDetailView()` directly in the
`NavigationSplitView` detail column with **no `NavigationStack`**, while
`BookDetailView` pushes the reader via
`.navigationDestination(isPresented: $readerActive)`
(`BookDetailView.swift:137-139`). A `navigationDestination` without an
enclosing stack is inert (runtime warning, no push), so on iPad "Continue
reading", Contents-row jumps, and Notes-section jumps would all do nothing.
**Repro loop (diagnosing-bugs):** iPad simulator + `MARGINS_IMPORT_FIXTURE`,
tap a book in the sidebar, tap Continue reading; watch the console for the
`navigationDestination` warning. Pass/fail signal: reader appears or not.
**Fix:** wrap the detail column in `NavigationStack { BookDetailView() }`.
While here, note the iPhone/iPad branch flips wholesale on
`horizontalSizeClass` (`LibraryScene.swift:22`) — entering Split View or
Slide Over on iPad flips regular→compact and rebuilds the entire navigation
tree, dropping the user's place. Fix if cheap (single `NavigationSplitView`
handles compact by collapsing on its own); otherwise record it as a known
limitation in `docs/ios-plan.md`.
**Verify:** iPad simulator: sidebar → detail → reader push works; back
returns to detail; same flow still works on iPhone.

### 2.2 Reader tap zones measured against the window, not the view — MEDIUM
`apple/ios/Margins/Reader/ReaderScene.swift:325-344`: the tap location is in
the web view's local space but the thirds are computed from
`keyWindow.bounds.width`. Correct on full-screen iPhone; wrong the moment the
reader is narrower than the window (iPad split view, Slide Over, Stage
Manager) — forward taps land in the center zone, back zone grows, etc. Also
grabs `connectedScenes.first`, which is fragile.
**Fix:** measure the view itself (wrap in `GeometryReader`, or use
`.onTapGesture` + a captured size from `.onGeometryChange`); delete
`tapZoneWidth`.
**Verify:** iPad simulator in 50/50 Split View: tap left/center/right thirds
of the *reader*, confirm back/chrome-toggle/forward respectively.

## Phase 3 — reader capture & state polish

### 3.1 `[VERIFY-FIRST]` Highlight overlays race a fixed 600 ms sleep — MEDIUM
`ReaderScene.swift:93-101`: after a chapter loads, the code sleeps 600 ms and
then paints highlight overlays. First open of a large EPUB (fetch + epub.js
open + display) routinely exceeds 600 ms, so saved highlights silently fail
to paint; the comment even admits the hazard.
**Repro loop (diagnosing-bugs):** commit a highlight
(`MARGINS_HIGHLIGHT_FIXTURE=1`), relaunch into the reader, check whether the
overlay is painted (screenshot or `[reader-js]` console lines).
**Fix:** drive the restore from a real signal instead of a timer — e.g. call
`restoreHighlights` from the bridge when the first `relocated` message for
the current chapter arrives (the rendition is provably live then), keeping a
re-entrancy guard so re-adding stays idempotent (epub.js dedupes by range).
**Verify:** the repro loop above goes green even with a cold start.

### 3.2 Return-from-reader shows a stale position — LOW
`BookDetailView.swift:54-58` reloads the position when `readerActive` flips
false, but the position save is debounced 0.8 s
(`apple/Sources/MarginsModel/ReaderModel.swift:41`), so the reload can read
the previous value.
**Fix:** call `reader.flushPositionSave()` in the reader's back action (and/or
before the reload), mirroring what the scene already does on backgrounding.
**Verify:** page forward, immediately tap back: progress % and bookmark match
the page you left.

### 3.3 Export markdown is cached forever — LOW
`BookDetailView.swift:277-288`: the first "Export .md" tap renders markdown
into `@State exportMarkdown`; from then on the ShareLink shares that snapshot
even after new marks/notes/clear-all. Also the first tap doesn't open the
share sheet (two-tap flow).
**Fix:** invalidate `exportMarkdown` whenever `library.compiledNotes` changes
(`.onChange`), or drop the cache and render on demand.
**Verify:** export, add a mark, export again → new mark present.

### 3.4 Capture drafts bleed across capture types — LOW
`apple/ios/Margins/Reader/CaptureViews.swift:23-25`: the autosaved draft key
is per book+chapter only, so an abandoned draft from a page-anchored note
pre-fills the next *selection* capture (different quote, same chapter).
**Fix:** include a discriminator in the key (e.g. `"sel"` vs `"page"`), or
clear the draft when the sheet opens with a selection.
**Verify:** start a page note, type, swipe down after deleting the text…
simpler: dismiss with text (it commits), then confirm a fresh selection
capture opens empty.

### 3.5 End-of-chapter prompt fires on TOC jumps — LOW
`ReaderScene.swift:194-211`: `detectChapterFinish` only requires "was on the
last page, now in a later chapter", so jumping from a chapter's last page to
chapter 12 via the TOC shows "Finished …" for a chapter the user may not have
finished reading. **Fix:** additionally require the new chapter be the
immediate successor (`reader.chapter?.index == finished.index + 1`).
**Verify:** unit-test the predicate if you extract it (nice `[TDD]`
candidate — it's pure); otherwise simulator spot-check.

## Phase 4 — shared-layer issues surfaced by iOS

### 4.1 `[VERIFY-FIRST]` Evicted iCloud files skip materialization — MEDIUM
`apple/Sources/MarginsModel/LibraryLocation.swift:70`:
`guard FileManager.default.fileExists(atPath: path) else { return path }`.
An **evicted** ubiquitous file exists only as a `.name.icloud` placeholder, so
`fileExists` at the logical path returns false and the function returns the
un-downloaded path — exactly the case it was written to handle. Covers (its
only current caller, `CoverView.swift:54`) would never load on a
freshly-synced device.
**Repro:** hard without two devices — at minimum unit-test the decision logic
by injecting providers (`LibraryLocation` is already injection-friendly), and
reproduce the placeholder naming with a local fixture if feasible.
**Fix:** don't early-return on missing file; attempt
`startDownloadingUbiquitousItem` (it accepts the logical URL of a
placeholder) and fall through to the polling loop; keep a bounded timeout.
Treat "no such item at all" as the pass-through case by catching the throw.
**Verify:** `MarginsTests` for the pure parts; live verification is blocked on
the Apple Developer approval — record that in the commit message.

### 4.2 `bridge` binding mutated during view update — LOW
`apple/ios/Margins/Reader/ReaderBridge.swift:63-67`: `makeUIView` assigns
`bridge = context.coordinator`, i.e. writes SwiftUI state during view update
("Modifying state during view update" undefined behavior; the chrome may see
a nil bridge for a frame or trip the runtime warning).
**Fix:** defer the write (`Task { @MainActor in bridge = … }`) or expose the
coordinator via a callback set in `onAppear`.
**Verify:** launch into the reader with the runtime-issues log visible; the
warning must be gone and chrome buttons must still page.

### 4.3 `[VERIFY-FIRST]` Doubled chrome in the reader — LOW
`ReaderScene.swift:58-60` keeps the system navigation bar visible while
`chromeVisible`, *and* draws a custom `topBar` (line 257) with its own back
button and title — likely two stacked headers with duplicate back affordances.
**Repro first** (screenshot on iPhone simulator), then pick one: hide the nav
bar permanently (`.toolbar(.hidden, for: .navigationBar)`) and keep the
custom chrome, or drop the custom top bar into toolbar items.

## Phase 5 — final review

1. Re-run everything: `swift run --package-path apple MarginsTests`, iOS
   simulator build, and one manual pass of: import → grid → detail → reader →
   selection note → highlight → chapter-note editor → search → delete book,
   on iPhone **and** iPad destinations.
2. Invoke **`code-review`** with fixed point `c40e682` (Standards axis at
   minimum; Spec axis against `docs/ios-plan.md` if the tracker doc exists).
   Address or explicitly waive each finding.
3. Do not commit unless the user asked; leave the working tree ready for
   review. Suggested commit granularity if commits are requested: one commit
   per phase, `BUG …` prefixes per repo convention.
