# Margins — agent guide

EPUB reader with two frontends over one Rust core: a native SwiftUI macOS app and an iOS app — all Apple targets share one SwiftPM package in `apple/`. Annotations live on disk as markdown + JSON — see `docs/storage.md`. Frontend architecture: `docs/architecture.md`.

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
CHORE Reformatted Rust with rustfmt
DOCS Document library sync workflow
```

## Project map

```
crates/margins-core/   # the domain core (no UI)
  config.rs            # data dir / library root from env
  library.rs           # import EPUB, book catalog
  notes.rs             # markdown + YAML frontmatter CRUD
  sync.rs              # export/import library trees
  epub_meta.rs         # EPUB spine/metadata parsing
crates/margins-ffi/    # UniFFI bridge for Swift (thin)
apple/                 # shared Apple SwiftPM package (macOS + iOS)
  Package.swift        # targets: MarginsFFI (xcframework), margins_ffiFFI,
                       # MarginsCore, MarginsModel, Margins (macOS app),
                       # MarginsTests; products MarginsCore/MarginsModel
                       # are consumed by the iOS app's Xcode project
  Sources/MarginsCore/ # generated bindings + CoreStore actor
  Sources/MarginsModel/# LibraryModel, ReaderModel, ReaderResource, ReaderKeymap,
                       # LibraryLocation (iCloud root, materialization, conflicts)
  Sources/Margins/     # macOS SwiftUI views, reader webview glue, key routing
  Sources/MarginsTests/# Swift Testing suite (runner executable)
  ios/                 # iOS app: Margins.xcodeproj + Sources (SwiftUI scenes)
build/MarginsFFI.xcframework/  # generated (make core / make ios-core)
scripts/               # build-core.sh, build-xcframework.sh, make-app.sh
```

## Conventions

- Keep annotation storage plain-text; do not introduce a database without strong reason
- Sensitive paths belong in `.env`, never committed
- Match existing minimal/zathura-like UI patterns (dark, keyboard-first)
- GPL-3.0-or-later — preserve license on distribution

## Useful commands

```bash
cargo test --workspace        # from the repo root (core + ffi)

make core        # rebuild margins-ffi, regenerate Swift bindings, refresh
                 # the macOS slice of build/MarginsFFI.xcframework
make ios-core    # also build the iOS device/simulator xcframework slices
make ios-archive # Release iOS archive at build/Margins.xcarchive (needs ASC app record + Signing.local.xcconfig)
make ios-bump    # bump CURRENT_PROJECT_VERSION (run before every TestFlight upload)
                 # (needs full Xcode: the zip stack's C deps require the
                 # iOS SDK, which Command Line Tools do not ship)
make mac-build   # build the macOS Swift package
make mac-test    # run the macOS Swift Testing suite
make mac-run     # assemble + open build/Margins.app
make mac-app-universal  # universal (arm64 + x86_64) build/Margins.app; needs full Xcode
make bump VERSION=x.y.z  # bump version everywhere, commit, tag vx.y.z
```

The macOS app builds with Command Line Tools alone. The **iOS app needs
full Xcode**: `make ios-core` for the xcframework slices, then open
`apple/ios/Margins.xcodeproj` (or `make ios-build`-style `xcodebuild`) —
see `docs/ios-plan.md`. The iOS library
root lives in the iCloud Documents container when available, falling
back to local `Documents/Library` at runtime (`LibraryLocation`);
DEBUG launch env vars
(`MARGINS_IMPORT_FIXTURE`, `MARGINS_SEARCH_FIXTURE`, `MARGINS_DELETE_FIXTURE`)
drive simulator verification flows. Device signing uses the team ID in
`apple/ios/Signing.local.xcconfig` (gitignored — created from
`Signing.local.xcconfig.example`; never commit it).

macOS tests use Swift Testing (`import Testing`) via the `MarginsTests`
runner executable — `swift test` silently runs nothing on a CLT-only
toolchain, so always verify with `make mac-test`.

## Agent tasks

When modifying notes storage, update `docs/storage.md` and ensure `_index.json` stays consistent. When adding keybindings, update the README (both frontends). When changing the FFI surface, run `make core` so the Swift bindings regenerate.
