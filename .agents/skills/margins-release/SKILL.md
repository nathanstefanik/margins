---
name: margins-release
description: Build and validate signed iOS and macOS Margins apps, upload to App Store Connect, distribute to every TestFlight group, verify beta review state, and preserve release evidence before cleanup.
---

# Margins Apple release workflow

Use this skill for Apple distribution tasks, including build-only requests.
It is the canonical workflow; `AGENTS.md` and `README.md` link here.
Other agents can read this file directly without skill-tool support.

## Scope and authorization

- Only perform the stages the user requested. Reading this skill is not authorization to publish.
- Uploading to App Store Connect and distributing through TestFlight are not a public App Store release. Public App Store submission/release needs separate instructions and authorization.
- `--confirm` flags record operator intent; they do not replace explicit user authorization.
- Never expire builds, cancel reviews, revoke certificates, delete signing assets, or replace an existing release artifact without approval for that specific action.
- If an older build blocks beta review, report the platform, version/build, and review state; ask to expire that specific build or wait. Never silently cancel it.
- Never print keys, JWTs, passwords, or the contents of `.env`. Do not weaken CI or signing/security settings to make a release succeed.

## Public instructions, private configuration

Keep commands and scripts in Git. Keep real account IDs, signing identities,
profile/keychain paths, tester metadata, and receipts local. Do not embed
credential values in skills, even private skills.

Prerequisites: full Xcode 26.x selected with `xcode-select`, Python 3,
OpenSSL, an existing App Store Connect app with both platforms, API access
for the requested operations, and provisioned distribution signing assets.
Do not discover or create new credentials; ask if authorized assets are missing.

Export these from the existing gitignored `.env` or an approved secret store:

| Variable | Use |
| --- | --- |
| `KEY_ID`, `ISSUER_ID` | App Store Connect API authentication |
| `API_PRIVATE_KEYS_DIR` | Optional directory containing `AuthKey_<KEY_ID>.p8`; defaults to `~/.appstoreconnect/private_keys` for the Python helper |
| `MAC_APP_IDENTITY` | Apple Distribution signing identity |
| `MAC_INSTALLER_IDENTITY` | Mac Installer Distribution signing identity |
| `MARGINS_PROFILE` | Active `MAC_APP_STORE` provisioning profile |
| `MARGINS_KEYCHAIN` | Optional keychain containing the signing identities |
| `MARGINS_KEYCHAIN_PASSWORD` | Optional unlock password; never print it |
| `MARGINS_IOS_EXPORT_OPTIONS` | Path to a local App Store export-options plist |

The iOS project optionally includes gitignored
`apple/ios/Signing.local.xcconfig`, created from its tracked example.
Do not put actual team/account values into tracked files.

If additional private operator notes are needed, keep them in a
machine-local skill outside this repository, e.g.
`~/.agents/skills/margins-release-local/SKILL.md` (a `*-local/` skill
inside the worktree is gitignored too). User-level skills are not
transferred to new machines or cloud agents; provision private
configuration separately. The public skill is complete without it.

From the repository root, load a trusted local `.env` without echoing it:

```sh
set -a
. ./.env
set +a
```

## 1. Preflight and reserve a new build

1. Inspect the working tree, current branch, `apple/VERSION`, iOS
   `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, requested scope, and CI.
2. Create a new evidence directory under gitignored `build/`, or outside
   every worktree scheduled for deletion. Set `RELEASE_DIR` to its absolute
   path. Never reuse an existing receipt filename.
3. Capture current App Store Connect state:

   ```sh
   python3 scripts/appstore-connect.py snapshot "$RELEASE_DIR/asc-before.json"
   ```

   The helper discovers the app by bundle ID and paginates builds/groups.
   Match each build to its included `preReleaseVersion` to identify platform
   and marketing version. Include expired builds when checking used numbers.
   Do not assume iOS and macOS have the same expiration/review state.

4. Choose a fresh positive integer `BUILD_NUMBER` for both platforms,
   greater than the local iOS number and previously used numbers for the
   target train on either platform. Never reuse an expired build number.
   A concurrent release can consume the number; recheck before uploading.
5. Set the exact number, then commit the build-number change if commits
   were requested:

   ```sh
   ./scripts/bump-build.sh "$BUILD_NUMBER"
   ```

   The no-argument script increments by only one; it does not consult
   App Store Connect. macOS packaging defaults to build **1**, so always
   pass the chosen `MARGINS_BUILD_NUMBER` explicitly.

## 2. Verification and integration

For a requested PR workflow, commit/push only when authorized, create the
PR with `gh`, inspect its checks, fix failures, and merge only after required
checks pass. Inspect current CI instead of hardcoding a past test count.

The current equivalent full-suite partitions are:

```sh
swift test --package-path apple --skip 'ReaderLayoutIntegrationTests|ReaderLayoutMatrixTests|ReaderRevealTests'
swift test --package-path apple --filter 'ReaderLayoutIntegrationTests|ReaderLayoutMatrixTests|ReaderRevealTests'
make ios-build
```

The matching skip/filter expressions must cover every test. Do not disable
WebKit checks or increase timeouts merely to make a failed run pass.

Prefer building from the clean, integrated commit. If prebuilding while CI
runs, compare all app/build inputs against the merged commit before upload.
Never upload an older artifact after integrating changed app sources.
Record the integrated commit and any explicitly verified build-source equivalence.

## 3. Build both signed artifacts

Use a clean output location; existing packaging scripts replace
`build/Margins.app`, and Xcode writes `build/Margins.xcarchive`.
Preserve earlier artifacts first. Do not run two packaging jobs against the
same worktree/output paths.

```sh
make ios-archive
xcodebuild -exportArchive \
  -archivePath build/Margins.xcarchive \
  -exportPath "$RELEASE_DIR/ios-export" \
  -exportOptionsPlist "$MARGINS_IOS_EXPORT_OPTIONS" \
  -allowProvisioningUpdates

MARGINS_BUILD_NUMBER="$BUILD_NUMBER" \
MARGINS_MAS_OUTPUT="$RELEASE_DIR/Margins-mas.pkg" \
make mas-pkg
```

The local export-options plist should use the current Xcode
`app-store-connect` method, the authorized signing/provisioning settings,
and `manageAppVersionAndBuildNumber = false` so export does not silently
change the reserved number. Do not commit concrete export options.

For an automatically signed archive, this is a minimal local plist template.
Replace the team placeholder only in the private file. Reuse existing
approved options when available; a manually signed archive needs the
matching manual signing identity/provisioning-profile mappings instead.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>LOCAL_APPROVED_TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
```

Before upload:

- Inspect each app's `CFBundleIdentifier`, `CFBundleShortVersionString`,
  and `CFBundleVersion`; both must match the intended bundle/version/build.
  Inspect the exported IPA, not just the archive.
- Verify macOS contains arm64 and x86_64 and that both apps bundle the
  integrated `MarginsModel/Resources/reader` resources.
- Verify signatures and entitlements, including sandbox/iCloud settings.
  `codesign --verify` alone does **not** prove the profile allows the certificate.
- For Mac validation error **90284**, decode the profile with `security cms`,
  compare public certificate fingerprints with its `DeveloperCertificates`,
  and refresh the existing active profile if needed. A same-named cached
  profile can contain an old certificate. Do not create/revoke assets blindly.
- Preserve SHA-256 hashes, build logs, archive/export options, source commit,
  and profile/certificate verification in local receipts, not Git.

## 4. Validate, then upload

The wrapper validates every supplied artifact before uploading any of them.
It creates a fresh private log directory under `RELEASE_DIR`. It does not
load `.env` automatically, change signing settings, or infer release authorization.

```sh
sh scripts/apple-upload.sh validate "$RELEASE_DIR" \
  "$RELEASE_DIR/ios-export/Margins.ipa" "$RELEASE_DIR/Margins-mas.pkg"
```

After explicit upload authorization:

```sh
sh scripts/apple-upload.sh upload --confirm "$RELEASE_DIR" \
  "$RELEASE_DIR/ios-export/Margins.ipa" "$RELEASE_DIR/Margins-mas.pkg"
```

These use current Xcode commands:
`xcrun altool --validate-app PATH --api-key "$KEY_ID" --api-issuer "$ISSUER_ID"`
and `--upload-package PATH --wait` with the same authentication.
Do not use the older `--upload-app` examples.

`--wait` completes upload processing, not external beta review. Capture a
new snapshot after upload, identify the exact version/build on each platform,
and require `processingState = VALID` and `expired = false`. Do not guess
build UUIDs, app IDs, or group IDs from a previous release.

## 5. Distribute to all current TestFlight groups

Create a private JSON manifest under `RELEASE_DIR` from the captured state.
The placeholders below must be replaced with inspected current values:

```json
{
  "appID": "<discovered app ID>",
  "bundleID": "io.github.nathanstefanik.margins",
  "version": "<apple/VERSION>",
  "buildNumber": "<reserved positive integer as a string>",
  "builds": {
    "IOS": "<validated iOS build UUID>",
    "MAC_OS": "<validated macOS build UUID>"
  },
  "notes": {
    "IOS": "<truthful tester-facing release notes>",
    "MAC_OS": "<truthful tester-facing release notes>"
  },
  "outputDirectory": "<absolute RELEASE_DIR>",
  "submitExternalReview": true
}
```

The helper defaults review submission to **false** when omitted. Set it
to true only when external TestFlight distribution was requested.
The helper:

- Discovers all current internal/external groups using the app's collection,
  including pagination; no group IDs or names are hardcoded.
- Preflights every selected build before any mutation: exact app, bundle,
  platform, version, build number, processing validity, and expiration.
- Sets `en-US` tester notes, enables automatic notifications, adds only
  missing group memberships, and avoids duplicating existing review submissions.
- Saves private before/after receipts and verifies group membership and
  notification settings through included relationships. A separate related
  beta-group GET can be forbidden even when `include=betaGroups` works.
- Fails closed on missing/truncated included relationships rather than
  claiming that every group received the build.
- Never expires a build or cancels a review.

After explicit distribution authorization:

```sh
python3 scripts/appstore-connect.py distribute \
  "$RELEASE_DIR/distribution-manifest.json" --confirm
```

Exit **2** means group assignment was verified but external review remains
blocked/rejected; it is not a complete external rollout. Any other failure
requires inspecting the saved evidence before retrying. A failed operation
may already have changed notes/groups; do not assume transactional rollback.

For `ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW`, capture fresh state and
inspect the earlier build. Ask permission before expiring it. Once cleared,
resume with a manifest containing only the pending platform; do **not**
reupload already processed builds. Each invocation preserves a new receipt
directory.

## 6. Verify and report actual availability

Capture fresh inspections without overwriting earlier evidence:

```sh
python3 scripts/appstore-connect.py inspect "$IOS_BUILD_ID" "$RELEASE_DIR/ios-final.json"
python3 scripts/appstore-connect.py inspect "$MACOS_BUILD_ID" "$RELEASE_DIR/macos-final.json"
```

Report each platform separately:

- Upload processing: `VALID` is distinct from tester availability.
- Internal testing: report `internalBuildState`, such as `IN_BETA_TESTING`.
- Group assignment: verified membership is distinct from external access.
- External testing: `READY_FOR_BETA_SUBMISSION`, `WAITING_FOR_BETA_REVIEW`,
  and `IN_BETA_REVIEW` are **not** live external distribution.
- Beta submission: report the related `betaReviewState` separately, e.g.
  `WAITING_FOR_REVIEW`.
- External testing is available only when the current external state
  establishes it, such as `IN_BETA_TESTING`. Do not promise Apple's timing.

Preserve a private final receipt with source commit, version/build, artifact
hashes, validation/upload results, both platform states, assigned groups,
and any outstanding blocker. Never commit actual IDs or tester metadata.

## 7. Cleanup only when requested

Update requested PR descriptions/comments yourself. Delete merged branches
only when requested. Preserve artifacts and receipts outside a temporary
worktree before removing it.

Inspect `git status` and `git worktree list`; do not force-remove a dirty
worktree or discard untracked user files. Remove only the explicitly
authorized temporary worktree. Leave the primary worktree, local credentials,
signing assets, and preserved release outputs intact.
