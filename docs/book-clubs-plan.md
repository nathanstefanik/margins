# Development plan: private book clubs

Status: in progress · Owner: TBD · Last updated: 2026-09-11

## Goal

Book clubs as a **private, one-book, in-person discussion tool**. A club is a
small group of people reading the same EPUB, each keeping their own Margins
notes, with two capabilities:

1. **Manage the club** — admin vs member roles, private membership, a
   four-character invite code.
2. **See the group's thinking** — a derived, merged view of every member's
   notes for the book (and a markdown export of the same), with overlapping
   highlights clustered under one quoted passage so agreement and dissent are
   visible at a glance.

The merged view is the product. Book clubs build larger claims from many
minds; the job of the software is to put everyone's marginalia on one page,
not to become a feed.

## Locked product decisions

- **One book per club.** A club does not persist across readings, and member
  notes do not carry over between books. No "club library", no seasons.
- **No replies, threads, reactions, or feeds.** Discussion happens in person;
  the app only compiles notes.
- **Private.** No discoverability, no public clubs, no profiles. Joining is
  invite-code + share acceptance; the admin can remove members.
- **Members see derived/merged views only.** Another member's raw note files
  are never exposed through the UI. What crosses the network is a derived
  snapshot (`ClubMemberNotes`); what renders is the merged document
  (`ClubNotes`).
- **Spoiler protection on by default.** A user can never see another
  member's notes for the chapter they are currently reading or any later
  chapter. Own notes are always visible. It is a user setting
  (`SpoilerPolicy` in the core; toggle in app settings).
- **Transport is CloudKit + `CKShare`.** No server to run, Apple-native
  private sharing, roles map to share owner/participant. The core stays
  platform-agnostic and file-based; CloudKit lives in a sync layer.
- **Overlapping CFI ranges become one passage.** Marks that overlap in the
  shared CFI space (everyone reads the same content-hash book, so the CFI
  space is shared) render as one quote with each member's thought stacked
  under it.

## Non-goals (this feature)

- Multi-book clubs, reading schedules, meetings, RSVPs, chat.
- Any public/social surface: profiles, discoverability, follower counts.
- CRDTs. Every member writes only their own snapshot, so there is nothing to
  merge at the field level; snapshots are single-writer by construction.
- Non-Apple platforms/auth.

---

## Architecture

```
MarginsCore (pure, phase 1)
  ClubModels.swift   Club · ClubMember · ClubMemberNotes · SpoilerPolicy
                     ClubNotes (merged view: ClubChapter · ClubPassage …)
  CFI.swift          CFI range parse + overlap (passage clustering)
  ClubCompile.swift  snapshot() · compile() · renderMarkdown()
  ClubCode.swift     4-char invite-code generate/normalize
        │
MarginsModel (phase 2–3)
  ClubStore.swift    local club files under {data_dir}/clubs/{club_id}/
  ClubSync.swift     CloudKit: CKShare records, snapshot push/pull
        │
macOS app (phase 4)                 iOS app (phase 5)
  ClubsView / ClubDetailView          ClubsScene / ClubDetailView
  ClubNotesView (merged + export)     ClubNotesView
```

The core has no I/O in phase 1. `ClubCompile.compile` is a pure function from
(club, snapshots, viewer position, policy) to a merged view, so the spoiler
and clustering rules are testable without an iCloud account or a device.

### Local storage (phase 2)

Club state is social, not library content: it syncs through CloudKit, not
the iCloud Drive library folder, so it lives in the app data directory.

```
{data_dir}/clubs/
  {club_id}/
    club.json                    # Club: name, book_id, invite_code, roster
    members/{member_id}.json     # ClubMemberNotes snapshot (self + received)
```

- One file per member snapshot keeps writes single-writer, so iCloud's
  file-level conflict handling is only ever for one person's own devices.
- Snapshots are derived artifacts: they can always be regenerated from the
  local book notes, so deleting one loses nothing.
- The spoiler setting is a local/global user setting, not club state; it
  belongs with app config, never in a shared record.

### CloudKit (phase 3)

- Enable the CloudKit service on the existing container
  (`iCloud.io.github.nathanstefanik.margins`), on iOS and macOS.
- Private database, custom zone `BookClubs`. Record types:
  - `Club` — `name`, `bookId`, `bookTitle`, `bookAuthor`, `createdAt`,
    `inviteCode`, `ownerMemberId`; carries the `CKShare`.
  - `Member` — `displayName`, `role` (`admin`/`member`), `joinedAt`,
    `memberId`.
  - `Snapshot` — `memberId`, `updatedAt`, `payload` (`CKAsset`, the JSON
    encoding of `ClubMemberNotes`).
- **Roles:** the share owner is the admin. `Member.role` mirrors it for the
  UI; CloudKit's participant permissions are the enforcement.
- **Invite code:** the code is a human handle, not a secret. A public
  database record `ClubInvite` maps `code → shareURL + clubName + bookTitle`,
  with an `expiresAt`; the admin can rotate or revoke it. 32⁴ ≈ 1M codes is
  guessable, so joining is still gated on accepting the `CKShare`, codes
  expire, and the admin can remove members. Rate-limit lookups client-side;
  if true pre-approval is required later, that needs a server (recorded as an
  open question, not v1).
- **Sync:** each member regenerates their own snapshot (debounced) when
  notes change and saves it; the club view fetches changed records with a
  stored change token. Snapshot records are single-writer, so conflicts are
  only between one member's own devices and last-writer-wins is safe.
- **macOS caveat:** CloudKit requires real signing/entitlements, which
  conflicts with the ad-hoc `make app` flow. The plan is iOS-first for
  iCloud testing; macOS gains a signed dev path or ships the club UI once
  signing is set up.

---

## Phase 1 — Core club domain (this change)

Pure Swift, no I/O, no UI. Implements the entire read/merge model so later
phases only add storage and transport.

**Files**

| File | Contents |
|------|----------|
| `MarginsCore/ClubModels.swift` | `ClubRole`, `ClubMember`, `Club`, `ClubMemberNotes`, `SpoilerPolicy`, `ClubMark`, `ClubPassage`, `ClubContribution`, `ClubChapter`, `ClubNotes`, `ClubExportOptions` |
| `MarginsCore/CFI.swift` | `CFIRange`, `CFI.parse`, `CFI.overlaps` |
| `MarginsCore/ClubCompile.swift` | `ClubCompile.snapshot`, `.compile`, `.renderMarkdown`, `.suggestedExportFilename`; `ClubMarks.cluster` |
| `MarginsCore/ClubCode.swift` | `ClubCode.generate`, `.normalize`, `.isValid` |
| `MarginsCore/Compile.swift` | `sanitizeFilenameComponent` private → internal (reused by club export naming) |

**Behavior contract**

- `ClubMemberNotes` is built by `ClubCompile.snapshot(_:memberId:displayName:)`
  from the local `CompiledNotes`; chapters with an empty body and no marks are
  dropped. It carries `bookId/bookTitle/bookAuthor/chapterCount/updatedAt`.
- `ClubCompile.compile(club:snapshots:viewerId:viewerChapterIndex:spoilerPolicy:)`
  - ignores snapshots whose member is not on the roster;
  - unions chapter keys across snapshots, ordered by `chapterIndex` then
    `chapterKey`;
  - keeps the viewer's own content always; hides any other member's content
    for chapters with `index >= viewerChapterIndex` when the policy is on
    (`nil` viewer position hides all other members' content);
  - reports hidden content as counts (`hiddenMemberCount`,
    `hiddenContributionCount`, `hiddenMarkCount`) and `othersHidden`, never
    as content;
  - clusters all visible marks into `ClubPassage`s via `ClubMarks.cluster`;
  - sorts contributions by `(displayName, memberId)` for determinism;
  - computes stats over visible content only; `chapterCount` comes from the
    snapshots' spine counts.
- `ClubMarks.cluster` unions marks whose CFI ranges overlap (same element
  path + overlapping offsets, or one path a strict prefix of the other). When
  a CFI is missing/unparsable, marks fall back to clustering on an identical
  whitespace-normalized, lowercased quote. A passage's quote is the longest
  member quote; its position is its earliest mark; its id is the sorted member
  mark ids joined.
- `renderMarkdown` emits: title, book line, stats, a spoiler banner when
  protected, a linked TOC, then per chapter a `### Passages` section (one
  quote, each member's mark body under a bold name) and a `### Notes`
  section (long-form bodies under bold names). Hidden content renders as an
  italic placeholder line, never as content. User headings are demoted like
  the personal export. Output is deterministic and contains no HTML.
- `ClubCode`: 4 characters from Crockford's base32 alphabet
  (`0-9A-Z` minus `I L O U`). `normalize` uppercases, maps `I/L → 1` and
  `O → 0`, drops whitespace and dashes, and returns `nil` unless exactly four
  alphabet characters remain.

**Testing** (`MarginsCoreTests`)

- `CFITests.swift` — point/range/assertion parsing, rejects malformed input,
  offset overlap (including touching), ancestor containment, unrelated paths.
- `ClubTests.swift` — code generation/normalization, role lookup, roster
  ordering, JSON round-trip of `Club`/`ClubMemberNotes`, snapshot derivation.
- `ClubCompileTests.swift` — merge across members, spoiler gating on/off and
  with a missing position, own-content visibility, hidden counts, clustering
  by CFI and by quote fallback, non-overlap separation, markdown shape and
  determinism, filename sanitization, empty club.

**Exit:** `swift test --package-path apple` green.

---

## Phase 2 — Local club store + `CoreStore` surface

**Files:** `MarginsCore/ClubStore.swift` (or `Clubs.swift`), `CoreStore`
methods, `docs/storage.md` section, tests.

- `createClub(bookId:name:member:) -> Club` — 10-char Crockford club id
  (same idiom as marks), fresh invite code, admin member.
- `listClubs() -> [Club]`, `getClub(id:) -> Club`, `updateClub(_:)`,
  `deleteClub(id:)`, `rotateInviteCode(clubId:) -> String`.
- `saveMemberSnapshot(clubId:snapshot:)`, `memberSnapshots(clubId:)`.
- `buildMemberSnapshot(clubId:memberId:displayName:)` — compiles the local
  book notes and converts via `ClubCompile.snapshot`.
- `clubNotes(clubId:viewerId:viewerChapterIndex:spoilerEnabled:) -> ClubNotes`
  and `renderClubNotesMarkdown(...)`.
- Persist the spoiler setting with `AppConfig` (default `true`).

**Exit:** tests cover create/join-less round-trip, snapshot rebuild, merge
through `CoreStore`, code rotation; `docs/storage.md` documents the layout.

---

## Phase 3 — CloudKit transport

**Files:** `MarginsModel/ClubSync.swift`, entitlements for both apps, tests
behind a `ClubSyncEngine` protocol with an in-memory fake.

- `createClubShare(club:) -> URL`, `acceptShare(from:)`, `sync(clubId:)`,
  `publish(snapshot:clubId:)`, `lookupInvite(code:)`, `revokeInvite(code:)`.
- Change-token persistence in the club directory; fetch/push on club view
  appear and after a local note save (debounced).
- Publish `ClubInvite` public records on create/rotate; delete on revoke.
- Map `CKShare` participants onto `ClubMember`; share owner is `admin`.

**Exit:** two simulators signed into different iCloud accounts can create,
join, and see each other's merged notes; unit tests cover the record mapping
and change processing with the fake engine.

---

## Phase 4 — macOS UI

**Files:** `MarginsModel/ClubModel.swift`; `Margins/ClubsView.swift`,
`ClubDetailView.swift`, `ClubNotesView.swift`, `JoinClubSheet.swift`; edits to
`SidebarView`, `BookDetailView` ("Start a Book Club…"), `MarginsCommands`
(menu items), `SettingsView` (spoiler toggle), `KeyHelp` + README if a
keybinding is added.

- Sidebar "Book Clubs" section; club detail shows roster, book, invite code
  (admin: copy/rotate), member count, and "Club Notes".
- Club notes view renders the merged document: chapter sections, passage
  cards (quote + stacked member notes), long-form notes, spoiler placeholder
  rows with hidden counts, and an "Export Club Notes…" action
  (`NSSavePanel`, default name from `suggestedExportFilename`).
- Create/join sheets; join takes a 4-character code.

**Exit:** `make build` + `swift test` green; manual flow on the sample
library.

---

## Phase 5 — iOS UI

**Files:** `ios/Margins/Clubs/…` scenes; edits to `LibraryScene` (add a Clubs
tab or section), `BookDetailView` ("Start a Book Club…"), app settings.

- Same information architecture as macOS, adapted to the iOS 26
  content-under-glass model: clubs are content, controls are system-first.
- Invite code entry with a keyboard-friendly 4-slot field; share sheet for
  the invite link; spoiler toggle in Settings.

**Exit:** `make ios-build` green; simulator flow with
`MARGINS_*_FIXTURE`-style fixtures for a club with three members.

---

## Phase 6 — Docs, polish, release

- `docs/storage.md` club section, `docs/architecture.md` module map,
  README feature paragraph.
- Export polish: meeting-brief options (passages only), copy-all.
- Privacy notes: what leaves the device (derived snapshots only), where
  codes are visible, how removal works.

---

## Risks / open questions

- **Invite-code enrollment vs true pre-approval.** `CKShare` acceptance is
  the join gate; an admin cannot approve before the joiner has access without
  a server. v1 accepts this (rotate/expire codes, remove members); revisit if
  that is not private enough.
- **Edition drift.** Different EPUB editions hash to different `book_id`s.
  v1 requires every member to import the same EPUB; a work-level id or
  quote-based matching is a future feature.
- **CFI overlap fidelity.** `CFI.swift` is intentionally partial: unknown
  constructs fail to `nil` and fall back to quote matching. That is
  acceptable for clustering; it is not a general CFI library.
- **CloudKit + ad-hoc signing.** The macOS `make app` flow may need a
  signed variant for CloudKit; iOS is the first iCloud test surface.
- **Public invite lookup.** The `ClubInvite` public record exposes club name
  and book title to anyone who guesses a live code. Codes expire and rotate;
  document it in the privacy notes.

## Commit slicing

1. `DOCS Add private book club implementation plan` (this file)
2. `FEAT Add private book club core domain` (phase 1)
3. `FEAT Persist local book clubs and member snapshots` (phase 2)
4. `FEAT Sync book clubs through CloudKit shares` (phase 3)
5. `FEAT Add book clubs to the macOS app` (phase 4)
6. `FEAT Add book clubs to the iOS app` (phase 5)
7. `DOCS Document book club storage and privacy` (phase 6)
