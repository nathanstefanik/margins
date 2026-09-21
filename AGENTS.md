# Margins — agent guide

EPUB reader with two frontends over one Swift core: a native SwiftUI macOS app and an iOS app — all Apple targets share one SwiftPM package in `apple/`. Annotations live on disk as markdown + JSON — see `docs/storage.md`. Frontend architecture: `docs/architecture.md`.

## Commit messages

Prefix every commit with a type tag and a short imperative summary:

| Prefix | Use for |
|--------|---------|
| `FEAT` | New user-facing capability |
| `BUG` | Bug fix |
| `CHORE` | Tooling, deps, formatting, config |
| `DOCS` | Documentation only |
| `REFACTOR` | Behavior-preserving code change |

Examples:

```
FEAT Add chapter note autosave on :w
BUG Fix OPF spine parsing for nested paths
CHORE Reformatted Swift with swift-format
DOCS Document library sync workflow
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
                       # Marks, Frontmatter, Compile, Search, FileStore,
                       # Files, AppConfig, Text, CoreStore (actor facade)
  Sources/MarginsModel/# LibraryModel, ReaderModel, ReaderResource, ReaderKeymap,
                       # LibraryLocation (iCloud root, materialization, conflicts),
                       # EpubMirror (eviction-proof local EPUB copies)
  Sources/Margins/     # macOS SwiftUI views, reader webview glue, key routing
  Tests/               # MarginsModelTests + MarginsCoreTests (Swift Testing);
                       # MarginsCoreTests/Fixtures/legacy-library/ is a library
                       # written by the pre-Swift core — keep it reading
  ios/                 # iOS app: Margins.xcodeproj + SwiftUI scenes
scripts/               # make-app.sh, bump-version.sh, bump-build.sh,
                       # vendor-reader.sh
```

## Conventions

- Keep annotation storage plain-text; do not introduce a database without strong reason
- Sensitive paths belong in `.env`, never committed
- Match existing minimal/zathura-like UI patterns (dark, keyboard-first)
- iOS UI follows the iOS 26 content-under-glass model: system controls
  first, glass only on the control plane (never content), layout by size
  class — never `interfaceOrientation`. Shared tokens live in
  `apple/ios/Margins/DesignTokens.swift`.
- GPL-3.0-or-later — preserve license on distribution

## Useful commands

```bash
swift test --package-path apple   # the Swift Testing suite (core + model)

make test        # the same suite via make
make build       # build the Swift package
make ios-build   # build the iOS app for the simulator (no signing)
make ios-archive # Release iOS archive at build/Margins.xcarchive (needs ASC app record + Signing.local.xcconfig)
make ios-bump    # bump CURRENT_PROJECT_VERSION (run before every TestFlight upload)
make mas-pkg     # sandboxed, distribution-signed Mac App Store pkg (needs MAS identities + profile)
make app         # assemble build/Margins.app (ad-hoc signed)
make run         # app + open it
make app-universal  # universal (arm64 + x86_64) build/Margins.app; needs full Xcode
make bump VERSION=x.y.z  # bump version everywhere, commit, tag vx.y.z
```

Everything needs **full Xcode** (26.x): the iOS SDK for `ios-build` and the
iOS targets. The iOS library root lives in the iCloud Documents container
when available, falling back to local `Documents/Library` at runtime
(`LibraryLocation`); DEBUG launch env vars (`MARGINS_IMPORT_FIXTURE`,
`MARGINS_SEARCH_FIXTURE`, `MARGINS_DELETE_FIXTURE`,
`MARGINS_EVICT_FIXTURE`, `MARGINS_OFFLINE_FIXTURE`) drive simulator
verification flows. FileStore refuses evicted iCloud reads rather than
waiting; see `docs/architecture.md` (iOS) and `docs/testing/ios-offline.md`.
Device signing uses the team ID in
`apple/ios/Signing.local.xcconfig` (gitignored — created from
`Signing.local.xcconfig.example`; never commit it).

Tests use Swift Testing (`import Testing`) via the
`MarginsModelTests`/`MarginsCoreTests` test targets — always verify with
`swift test --package-path apple`.

## Agent tasks

When modifying notes storage, update `docs/storage.md` and ensure `_index.json` stays consistent. When adding macOS keybindings, update the README table and `KeyHelp.swift` (the iOS app has no vim keymap). When changing the `CoreStore` surface, keep the method list and labels the apps call — check `MarginsModel`, both apps (macOS + iOS), and the tests.
