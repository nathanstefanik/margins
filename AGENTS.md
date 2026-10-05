# Margins — agent guide

EPUB reader with two frontends over one Swift core: a native SwiftUI macOS app and an iOS app — all Apple targets share one SwiftPM package in `apple/`. Annotations live on disk as markdown + JSON — see `docs/storage.md`. Frontend architecture: `docs/architecture.md`.

## Commit messages

Follow Google's CL description guidance
(https://google.github.io/eng-practices/review/developer/cl-descriptions.html).
Commits before this rule used `FEAT`/`BUG`/`CHORE`/`DOCS`/`REFACTOR` prefixes
and AI `Co-Authored-By` trailers; leave that history alone, don't copy it.

- **Subject:** one imperative sentence that stands alone in `git log
  --oneline`. Sentence case, no trailing period, aim for 60 characters
  (72 at most). No type tags or Conventional Commit prefixes.
- **Body** (after a blank line) for anything non-trivial: what changed and
  why, the context and decisions the diff doesn't show, and known
  shortcomings or follow-ups. Plain text wrapped at 72 columns, no
  Markdown.
- **Trailers** in the final paragraph, one `Key: value` per line:
  `Test:` (how it was verified, when not obvious), `Fixes:` (issue refs),
  and `Assisted-by: <tool>` (e.g. `Assisted-by: Devin`) when an AI tool
  materially wrote or shaped the change.
- Never add `Co-authored-by` for AI tools, "Generated with …" lines, emojis,
  or AI-added `Signed-off-by`. The human committer is the author.
- PR titles follow the subject rules; no "Generated with …" footers.

Examples:

```
Add chapter note autosave on :w
Fix OPF spine parsing for nested paths
Reformat Swift with swift-format
Document the library sync workflow
```

```
Keep the reflow anchor instead of ratcheting it backward

After each settled reflow the transaction recaptured the new page start
as the anchor. That start is never later than the old anchor, so
successive resizes could land the reader a page early. Pin the anchor
until the next navigation.

Test: swift test --package-path apple --filter ReaderLayoutIntegration
Assisted-by: Devin
```

## Project map

```
apple/                 # shared Apple SwiftPM package (macOS + iOS)
  Package.swift        # targets: MarginsCore, MarginsModel, Margins (macOS
                       # app); products MarginsCore/MarginsModel are
                       # consumed by the iOS app's Xcode project
  VERSION              # the single version source (bump-version.sh writes
                       # it; make-app.sh and release.yml read it)
  Sources/MarginsCore/ # the core, no UI: Models, EpubParser, Library, Notes,
                       # Marks, Frontmatter, Compile, Search, Notebooks,
                       # TextAnalysis, TextExtract, TextIndex, FileStore,
                       # Files, AppConfig, Text, CoreStore (actor facade)
  Sources/MarginsModel/# LibraryModel, ReaderModel, ReaderResource, ReaderKeymap,
                       # LibraryLocation (iCloud root, materialization, conflicts),
                       # EpubMirror (eviction-proof local EPUB copies),
                       # NotebookModel, LibrarySearch
  Sources/Margins/     # macOS SwiftUI views, reader webview glue, key routing
  Tests/               # MarginsModelTests + MarginsCoreTests (Swift Testing);
                       # MarginsCoreTests/Fixtures/legacy-library/ is a library
                       # written by the pre-Swift core — keep it reading
  ios/                 # iOS app: Margins.xcodeproj + SwiftUI scenes
scripts/               # make-app.sh, make-mas-pkg.sh, bump-version.sh,
                       # bump-build.sh, vendor-reader.sh, make-icon.swift,
                       # make-reader-layout-fixtures.py, apple-upload.sh,
                       # appstore-connect.py, tests/
```

## Conventions

- Keep annotation storage plain-text; do not introduce a database without strong reason
- Derived indexes are plain files too — per device under the data dir, never in the library root (`docs/storage.md`)
- Sensitive paths belong in `.env`, never committed
- Match existing minimal/zathura-like UI patterns (dark, keyboard-first)
- iOS UI follows the iOS 26 content-under-glass model: system controls
  first, glass only on the control plane (never content), layout by size
  class — never `interfaceOrientation`. Shared tokens live in
  `apple/ios/Margins/DesignTokens.swift`.
- GPL-3.0-or-later — preserve license on distribution

## Pitfalls

Mistakes that have already cost time here:

- **SwiftUI `App` structs aren't views.** Don't wire models together in
  `App.init()`: the `@State` instances read there are discarded before the
  scene installs its own. Wire them from a root view's `.task`, as
  `MarginsApp.wireModels` does. For the same reason, read
  `@Environment(\.colorScheme)` in a root view; in an `App` it doesn't
  follow appearance changes.
- **macOS keys:** Return arrives as `"\r"` (keypad Enter as ETX).
  `ShellKeyboardController` maps both to the keymap's `"Enter"` by key code.
  In overlays the field editor can take Return before `onSubmit`; the ⌘K
  palette handles keys with its own monitor for that reason.
- **Reader palettes live in four places:** `ReaderPalette.swift`,
  `READER_THEMES` in `reader.js`, `reader.html`'s pre-paint rules, and the
  highlight table. Change them together; `ReaderResourceTests` fails on
  drift.
- **epub.js quirks** (highlights render in the outer document,
  `mapping.section()` is empty, no `orphans`/`widows`) are in the engine
  contract in `docs/testing/macos-reader-layout.md`. Read it before
  touching `reader.js` pagination or highlights.
- **Runtime checks** of `build/Margins.app` share the user's preferences
  domain, and an installed copy can shadow the build if launched by name.
  Follow `docs/testing/macos-runtime.md` (seeded `/tmp` library, launch by
  path, restore every key you write).
- **Environment blockers need the user:** an unaccepted Xcode license
  breaks even `git` (exit 69, `sudo xcodebuild -license accept`). An
  out-of-date CoreSimulator hangs `simctl` (`sudo xcodebuild
  -runFirstLaunch`). Ask; don't loop on retries.

## Useful commands

```bash
swift test --package-path apple   # the Swift Testing suite (core + model)

make test        # the same suite via make
make build       # build the Swift package
make ios-build   # build the iOS app for the simulator (no signing)
make ios-archive # Release iOS archive at build/Margins.xcarchive (needs ASC app record + Signing.local.xcconfig)
make ios-bump    # +1 CURRENT_PROJECT_VERSION; releases set an explicit number (see margins-release skill)
make mas-pkg     # sandboxed, distribution-signed Mac App Store pkg (needs MAS identities + profile)
make app         # assemble build/Margins.app (ad-hoc signed)
make run         # app + open it
make app-universal  # universal (arm64 + x86_64) build/Margins.app; needs full Xcode
make bump VERSION=x.y.z  # bump version everywhere, commit, tag vx.y.z
```

Everything needs **full Xcode** (26.x): the iOS SDK for `ios-build` and the
iOS targets. The iOS library root lives in the iCloud Documents container
when available, falling back to local `Documents/Library` at runtime
(`LibraryLocation`); DEBUG launch env vars
(`MARGINS_{IMPORT,SEARCH,DELETE,OPEN,CLUB,NOTEBOOK,EVICT,OFFLINE,CHROME,CAPTURE,HIGHLIGHT,EDITOR,CHAPTER_END}_FIXTURE`)
drive simulator verification flows. FileStore refuses evicted iCloud reads rather than
waiting; see `docs/architecture.md` (iOS) and `docs/testing/ios-offline.md`.
Device signing uses the team ID in
`apple/ios/Signing.local.xcconfig` (gitignored — created from
`Signing.local.xcconfig.example`; never commit it).

Tests use Swift Testing (`import Testing`) via the
`MarginsModelTests`/`MarginsCoreTests` test targets — always verify with
`swift test --package-path apple`.

CI runs the WebKit acceptance suites (`ReaderLayoutIntegrationTests`,
`ReaderLayoutMatrixTests`, and `ReaderRevealTests`) after the core/model
tests in a separate process. Keep CI's `--skip` and `--filter` patterns
identical so the two partitions cover the full suite.

## Agent tasks

When modifying notes storage, update `docs/storage.md` and ensure `_index.json` stays consistent. When modifying notebook storage, update `docs/storage.md` and `docs/commonplace.md`; `notebooks/_index.json` must stay derivable from the files. When adding macOS keybindings, update the README table and `KeyHelp.swift` (the iOS app has no vim keymap). When changing the `CoreStore` surface, keep the method list and labels the apps call — check `MarginsModel`, both apps (macOS + iOS), and the tests.

## Distribution verification

- For any iOS/macOS build, App Store Connect upload, or TestFlight distribution task, invoke the `margins-release` skill or read `.agents/skills/margins-release/SKILL.md` directly. It is the canonical release workflow; use its reusable scripts instead of recreating release commands.
- Publishing requires explicit user authorization. Never expire an existing build or cancel its review without approval for that specific action. Keep credentials, concrete account/signing details, tester metadata, and release receipts out of Git.
- Verify release-tool changes offline with `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` and `sh -n scripts/apple-upload.sh`. These tests use synthetic data and mocked Apple tools/API calls; verification must not publish or require Apple credentials.
- Validate signed artifacts with `xcrun altool --validate-app PATH --api-key "$KEY_ID" --api-issuer "$ISSUER_ID"` before upload. Current Xcode 26 altool uploads with `--upload-package PATH --wait` and the same authentication options; `--wait` reports processing completion.
- Local `codesign --verify` does not establish that the app's signing certificate is permitted by its embedded provisioning profile. For Mac validation error 90284, compare the public certificate fingerprints and refresh the existing active `MAC_APP_STORE` profile for the bundle ID before creating new signing assets. A cached profile with the same name can contain an older certificate.
- Keep provisioning profiles, export options, and release artifacts gitignored. Never upload an earlier main-only artifact after integrating a feature branch; verify the version/build and that bundled reader resources match the integrated source.
