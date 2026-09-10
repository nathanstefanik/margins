# Packaging plan: Homebrew (macOS) + notarization

Goal: make Margins installable via `brew install` on macOS, with signed and
notarized releases held to official homebrew/cask standards so later
submission to the official repo is a version bump, not a rework.

Decisions locked in:

- **Homebrew:** cask (GUI app), built to official homebrew/cask standards.
  Ship from a personal tap first; migrate to homebrew/cask once notability
  requirements are met (Phase 3).
- **macOS signing:** Developer ID signing + notarization (Apple Developer
  Program enrollment planned).
- **Scope:** repo/artifact readiness + publish channels we control. No
  third-party review queues yet.
- **Linux:** dropped with the non-Apple frontend (docs/apple-only-plan.md
  Phase 1). Margins is macOS and iOS only.

Name availability (checked 2026-09-03): no `margins` cask or formula in
Homebrew. The name `margins` is free.

---

## Phase 0 — Release hygiene — DONE

Every package manager downstream needs immutable, versioned, checksummed
artifacts at stable URLs. Current state:

- SPDX license `GPL-3.0-or-later` (LICENSE is GPLv3; matches README/AGENTS.md).
- App ID `io.github.nathanstefanik.margins` everywhere: the iOS project's
  bundle ID and the macOS bundle ID in `scripts/make-app.sh`.
- Single version source: `apple/VERSION`; `scripts/bump-version.sh`
  (or `make bump VERSION=x.y.z`) updates it plus the iOS
  `MARKETING_VERSION`, commits, and creates the annotated `vX.Y.Z` tag.
  `make-app.sh` reads `apple/VERSION` for Info.plist, and `release.yml`'s
  tag check verifies the tag against it.
- CHANGELOG.md (Keep a Changelog format).
- `.github/workflows/release.yml`, triggered on `v*` tag push, one macOS
  job on `macos-26` (Xcode 26.6): `make app-universal`, DMG packaging, then
  a `SHA256SUMS.txt` over all artifacts attached to the GitHub Release.
- `.github/workflows/ci.yml`, one macOS job on `macos-26`: `swift test`
  plus the iOS simulator build.

---

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

## Phase 3 — Migration to official homebrew/cask (deferred, gated)

Preconditions (homebrew/cask acceptance criteria as of 2026):

- Notability: roughly ≥75 GitHub stars, or ≥30 forks/watchers — audited by
  `brew audit --new-cask`.
- Notarized, stably versioned releases (done in Phases 0–1).
- No name conflict (verified: clear).

When met: submit `Casks/margins.rb` essentially unchanged via a PR to
homebrew/cask, then deprecate the tap copy with a `caveats`/README pointer.
Because Phases 1–2 already meet official standards, this step is
mechanical.
