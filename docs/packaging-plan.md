# Packaging plan: Homebrew (macOS) + Linux distro compliance

Goal: make Margins installable via `brew install` on macOS and via `.deb`/`.rpm`
artifacts and the AUR on Linux, with everything held to official
homebrew/cask and distro packaging standards so later submission to official
repos is a version bump, not a rework.

Decisions locked in:

- **Homebrew:** cask (GUI app), built to official homebrew/cask standards.
  Ship from a personal tap first; migrate to homebrew/cask once notability
  requirements are met (Phase 5).
- **macOS signing:** Developer ID signing + notarization (Apple Developer
  Program enrollment planned).
- **Linux:** `.deb` + `.rpm` on GitHub Releases, plus AUR packages.
- **Scope:** repo/artifact readiness + publish channels we control. No
  third-party review queues yet.

Name availability (checked 2026-09-03): no `margins` cask or formula in
Homebrew; AUR has only the unrelated `pdfcropmargins`. The names `margins`
and `margins-bin` are free.

---

## Phase 0 — Release hygiene — DONE

Every package manager downstream needs immutable, versioned, checksummed
artifacts at stable URLs. Shipped 2026-09-03:

- SPDX license `GPL-3.0-or-later` (LICENSE is GPLv3; matches README/AGENTS.md)
  declared once in `[workspace.package]` and inherited by all three crates.
- App ID `io.github.nathanstefanik.margins` everywhere: `tauri.conf.json`
  `identifier` and the macOS bundle ID in `scripts/make-app.sh`. Phase 3
  desktop/metainfo file names will use it from the start.
- Single version source: crates inherit `version` from `[workspace.package]`;
  `scripts/bump-version.sh` (or `make bump VERSION=x.y.z`) updates
  package.json, package-lock.json, tauri.conf.json, the workspace Cargo.toml,
  and Cargo.lock, commits, and creates the annotated `vX.Y.Z` tag.
  `make-app.sh` reads the version from Cargo.toml for Info.plist.
- CHANGELOG.md (Keep a Changelog format), seeded with the 0.1.0 entry.
- `.github/workflows/release.yml`, triggered on `v*` tag push (both jobs
  verify the tag matches the package version):
  - Linux job (ubuntu-22.04): `npm ci && npm run tauri build -- --ci`
    producing `.deb`, `.rpm`, and `.AppImage` for x86_64.
  - macOS job: `make mac-app-universal` (Rust staticlib for
    `aarch64-apple-darwin` + `x86_64-apple-darwin`, `lipo` into
    `target/release/libmargins_ffi.a`, Swift package built with
    `--arch arm64 --arch x86_64`), packaged as `Margins-vX.Y.Z.dmg`
    (ad-hoc signed until Phase 1).
  - `SHA256SUMS.txt` over all artifacts, attached to the GitHub Release
    along with everything else.

---

Phases 1–5 are **tabled for now**; revisit after the tag-driven release flow
has shipped a real release. When resumed: Phase 1 → 2 ship the macOS story,
Phase 3 → 4 the Linux story (the two tracks are independent and can run in
parallel). Phase 5 waits on repo traction.

## Phase 1 — macOS: Developer ID signing + notarization (deferred)

- [ ] Enroll in the Apple Developer Program ($99/yr); create a
  **Developer ID Application** certificate and an App Store Connect API key
  (for `notarytool` in CI).
- [ ] Extend `scripts/make-app.sh`:
  - Accept a `CODESIGN_IDENTITY` env var; fall back to ad-hoc for local dev.
  - Sign with hardened runtime: `codesign --force --options runtime
    --timestamp -s "$CODESIGN_IDENTITY"`. Add an entitlements plist only if
    the hardened runtime breaks something (JIT is not used; likely none
    needed).
- [ ] Notarization step in CI: `xcrun notarytool submit Margins.dmg
  --key ... --wait` then `xcrun stapler staple`.
- [ ] CI secrets: base64-encoded `.p12` + password (imported into a temp
  keychain), App Store Connect key ID / issuer ID / key file.
- [ ] Verify locally: `spctl -a -vv Margins.app` reports
  "accepted, source=Notarized Developer ID".

## Phase 2 — Homebrew cask (personal tap, official standards) (deferred)

- [ ] Create repo `nathanstefanik/homebrew-margins` with `Casks/margins.rb`:

  ```ruby
  cask "margins" do
    version "0.1.0"
    sha256 "<sha256 of dmg>"

    url "https://github.com/nathanstefanik/margins/releases/download/v#{version}/Margins-v#{version}.dmg"
    name "Margins"
    desc "Keyboard-first EPUB reader with file-based, AI-friendly annotations"
    homepage "https://github.com/nathanstefanik/margins"

    livecheck do
      url :url
      strategy :github_latest
    end

    depends_on macos: ">= :sonoma"  # matches Package.swift (.macOS(.v14))

    app "Margins.app"

    zap trash: [
      "~/Library/Application Support/Margins",
      "~/Library/Preferences/io.github.nathanstefanik.margins.plist",
      "~/Library/Saved Application State/io.github.nathanstefanik.margins.savedState",
    ]
  end
  ```

  Verify the actual data paths before writing the `zap` stanza (check where
  `MARGINS_DATA_DIR` defaults to on macOS and what the app writes under
  `~/Library`).
- [ ] Hold it to official standards even in the tap: `brew style --fix` and
  `brew audit --cask --online --strict margins` must pass clean.
- [ ] Automate: add a step to `release.yml` that opens a PR against the tap
  bumping `version`/`sha256` (a small script or
  `dawidd6/action-homebrew-bump-cask`).
- [ ] Document install: `brew install nathanstefanik/margins/margins`.

## Phase 3 — Linux `.deb` / `.rpm` compliance (deferred)

Tauri's bundler produces both; the work is making them *compliant*, not
making them exist.

- [ ] **Desktop entry** (freedesktop spec): configure Tauri's desktop file
  template (or ship `io.github.nathanstefanik.margins.desktop` via bundle
  files) with:
  - `Categories=Office;Viewer;`
  - `MimeType=application/epub+zip;` (registers Margins as an EPUB handler)
  - `StartupWMClass` matching the actual WM class, `Keywords=epub;reader;`
  - Validate with `desktop-file-validate`.
- [ ] **AppStream metainfo**: add
  `io.github.nathanstefanik.margins.metainfo.xml` (summary, description,
  screenshots, license `GPL-3.0-or-later`, `<launchable>`, release history),
  installed to `/usr/share/metainfo/` via the bundle `files` map. Validate
  with `appstreamcli validate`. This is what makes the app show up in GNOME
  Software / KDE Discover, and is mandatory if Flathub ever happens.
- [ ] **deb specifics** in `tauri.conf.json` `bundle.linux.deb`: `section`
  (`text` or `editors`… use `misc`/`viewers` judgment), correct `depends`
  (Tauri auto-detects webkit2gtk-4.1/gtk3; verify against Ubuntu 22.04 *and*
  24.04 package names), maintainer set to
  `Nathan Stefanik <nathan3359@icloud.com>` (or preferred contact). Run
  `lintian` on the built `.deb` and fix warnings.
- [ ] **rpm specifics** in `bundle.linux.rpm`: license `GPL-3.0-or-later`,
  epoch 0, correct depends. Run `rpmlint` and fix warnings.
- [ ] **Binary name**: ensure the installed binary is lowercase `margins` in
  `/usr/bin` (Cargo package is already `margins`).
- [ ] Smoke-test installs in containers: `ubuntu:24.04` (`apt install
  ./margins*.deb`), `fedora:latest` (`dnf install ./margins*.rpm`) — launch
  under `xvfb-run` or at least verify `margins --help`/binary links resolve
  (`ldd`).

## Phase 4 — AUR (deferred)

Two packages, conventional split:

- [ ] **`margins`** (source build, the canonical AUR citizen):
  - `PKGBUILD` building from the tagged GitHub tarball;
    `makedepends=(cargo nodejs npm)`, `depends=(webkit2gtk-4.1 gtk3
    libayatana-appindicator)` (mirror CI's apt list translated to Arch
    package names), `arch=(x86_64 aarch64)`, `license=(GPL-3.0-or-later)`.
  - Follow Rust package guidelines: `cargo fetch --locked` in `prepare()`,
    `--frozen` builds, respect `RUSTFLAGS`.
  - Install binary, desktop file, metainfo, and hicolor icons in `package()`.
- [ ] **`margins-bin`** (repackages the release `.deb`): fast install for
  users who don't want a full cargo+npm toolchain build.
- [ ] Both: generate `.SRCINFO` (`makepkg --printsrcinfo > .SRCINFO`), build
  in a clean chroot (`extra-x86_64-build` or an `archlinux:latest`
  container) before pushing, `namcap` the PKGBUILD and built package.
- [ ] Create AUR account, add SSH key, push both package bases.
- [ ] Automate bumps from `release.yml` with
  `KSXGitHub/github-actions-deploy-aur` (AUR SSH key as a CI secret).

## Phase 5 — Migration to official homebrew/cask (deferred, gated)

Preconditions (homebrew/cask acceptance criteria as of 2026):

- Notability: roughly ≥75 GitHub stars, or ≥30 forks/watchers — audited by
  `brew audit --new-cask`.
- Notarized, stably versioned releases (done in Phases 0–1).
- No name conflict (verified: clear).

When met: submit `Casks/margins.rb` essentially unchanged via a PR to
homebrew/cask, then deprecate the tap copy with a `caveats`/README pointer.
Because Phases 1–2 already meet official standards, this step is
mechanical.
