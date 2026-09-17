# Development plan: book club management QoL

Status: implemented · Last updated: 2026-09-17

Follows [docs/book-clubs-plan.md](book-clubs-plan.md). Each phase is one
commit. `swift test --package-path apple` green before the next.

## Goal

Reader saves publish the club snapshot. An existing club can be renamed,
your display name can change, and roster admin can move — CloudKit share
owner does not. Empty library: import on the create sheet, not a dead
**Create** button.

## Architecture

```
LibraryModel.notesDidChange(bookId)
        → ClubModel.schedulePublish(bookId)    // 1s latest-wins Task
        → ClubSync.publishOwnSnapshot          // every local club on that book
```

Pull remains `selectClub` / iOS pull-to-refresh. No subscriptions, no
`ClubPublisher`, no publish from `CoreStore`.

`Club.members[].role` = rename / remove / rotate / promote.
`Club.ownerMemberId` = delete-for-everyone. Promote changes role only.

## Locked

| Topic | Decision |
| --- | --- |
| Publish | 1s debounce after note/mark save. No `isBusy`. |
| Receive | Next club open (iOS: also pull-to-refresh). Selecting a club already `loadNotes`. Do not reload the club page from the save hook — the reader owns the detail pane while notes save. |
| Status | Keep **Sync My Notes** as flush/retry. Cancel the debounce and publish now. |
| Display name | Global `config.json` `club_display_name`. Prefill create/join. Edit later. Patch this member on every local club + republish those snapshots. Fail fast on CloudKit error. |
| Rename | Roster admin. `club.name =`; `updateClub`; `publishClub`. No `ClubInvite` rewrite. |
| Promote | Roster admin picks another member. That member becomes the only `.admin`; promoter becomes `.member`. `ownerMemberId` unchanged. |
| Delete / Leave | Owner: Delete, never Leave. Everyone else: Leave, never Delete. |
| Empty library | Create sheet empty state + Import. Do not disable **New Book Club**. |
| Out | Invite polish, join-time EPUB wizard, live club-page updates, CKShare ownership transfer, multiple roster admins, new tests as the deliverable |

### Who sees what

| Viewer | Rename / rotate / remove / promote | Delete | Leave |
| --- | --- | --- | --- |
| Admin + owner | yes | yes | no |
| Admin, not owner | yes | no | yes |
| Owner, not admin | no | yes | no |
| Member | no | no | yes |

`isAdmin` stays roster role. Do not reuse it for delete.

## Edge case: create club, no books

Today **Create** is disabled until a book is selected. With zero books
that can never happen. The picker is empty. Nothing explains why.

`library.books.isEmpty` means "this club has nothing to read," not
"Book not selected."

| State | Sheet |
| --- | --- |
| Empty library | No form, no **Create**. Copy: *A club reads one book from your library. Import an EPUB first.* **Cancel**, **Import EPUB…** |
| Import cancel/fail | Stay empty. Failure: existing `LibraryModel.errorMessage` |
| Books appear | Same sheet becomes the form. Select `library.selectedBookID ?? library.books.first?.id` |
| Library already has books | Form as today |

macOS: `ImportPanel.run(model: library)`. iOS: `.fileImporter` on this
sheet (`.epub`, `.data` → `library.importEpubs`). Join already has
`bookMissing`.

---

## Phase 1 — Owner, rename, display name, promote

**Commit:** `FEAT Add club owner, rename, display name, and admin promote`

No new Club helper types. Mutate `Club` in `ClubSync` the way
`removeMember` already mutates the roster.

### `Club` (`ClubModels.swift`)

Add `ownerMemberId: String` (`owner_member_id`).

- Init takes it. `createClub` sets it to `adminId`.
- Decode missing key → first roster admin id, else first member id.
- `isOwner(_ memberId: String) -> Bool`
- Do not add `renamed` / `withDisplayName` / `transferringAdmin`.

`adoptClubMemberId`: if `ownerMemberId == previous`, set it to the new
id (same loop that rewrites roster ids).

Fix every `Club(` call site so the package compiles (test helpers
included).

### `ClubSync`

```swift
func renameClub(clubId: String, name: String) async throws -> Club
func setDisplayName(_ name: String, memberId: String) async throws
func transferAdmin(clubId: String, to memberId: String) async throws -> Club
```

Mechanics only (same as `removeMember`). `ClubModel` enforces roles.
`transferAdmin`: target must be on the roster; everyone else `.member`.
`setDisplayName`: config + each local club this member is on, then
`publishOwnSnapshot` per club. Stop on first error.

### `ClubModel`

```swift
func isOwner(of club: Club?) -> Bool  // identity.memberId == club?.ownerMemberId
func renameSelectedClub(_ name: String) async -> Bool
func setDisplayName(_ name: String) async -> Bool
func promoteMember(id: String) async -> Bool
```

Trim; empty → `errorMessage`, false. Rename/promote require `isAdmin`.
Promote: not self, target on roster.

`docs/storage.md`: one sentence on `owner_member_id` and the decode
fallback.

Run: `swift test --package-path apple`

---

## Phase 2 — Auto-publish

**Commit:** `FEAT Auto-publish club snapshots after note saves`

### Hook

`refreshCompiledNotesAfterSave` returns early when the notes page is
hidden. Do not put the club hook there.

```swift
// LibraryModel
var onBookNotesChanged: (@MainActor (String) async -> Void)?

private func notesDidChange(bookId: String) async {
    await refreshCompiledNotesAfterSave(bookId: bookId)
    await onBookNotesChanged?(bookId)
}
```

Call `notesDidChange` from the five successful writes: `appendMark`,
`deleteMark`, `updateMark`, `saveChapterNote`, `saveChapterNoteText`.
Not bookmarks.

### Debounce

On `ClubModel`, one `Task` per `bookId`, cancel previous, `sleep` 1s,
then publish. No injectable sleeper, no `ClubPublisher`.

`schedulePublish(bookId:)`:

1. No matching club → return.
2. Do not set `isBusy`.
3. `publishOwnSnapshot` for each matching club (`displayName ?? "You"`).
4. Failure → `errorMessage`. Next save retries.

`publishOwnSnapshot()` (the button) cancels that book's task and
publishes immediately, then `loadNotes` as today.

Wire after `clubs.activate`:

- macOS `ContentView.task`: `model.onBookNotesChanged = { await clubs.schedulePublish(bookId: $0) }`
- iOS `AppModel.activate`: same on `library`

macOS `ContentView` banner: show `clubs.errorMessage` too (today it only
shows `LibraryModel`).

Run: `swift test --package-path apple`

---

## Phase 3 — UI (both apps)

**Commit:** `FEAT Add club management UI`

Empty-library branch + prefill + rename/name/promote/owner chrome.
Rename uses the existing bookmark pattern: `.alert` + `TextField`.
Promote/remove keep `confirmationDialog`.

### Both create sheets

Prefill Name from `clubs.identity.displayName`. Empty-library table
above. Do not disable **New Book Club** in `SidebarView`,
`MarginsCommands`, or `ClubsScene`.

### macOS

- Settings → Clubs: Name field → `setDisplayName`
- Club detail: admin rename alert; invite rotate still `isAdmin`;
  Delete iff `isOwner` else Leave; roster **Make Admin** (not self)

Promote copy:

> Promote {name} to admin? They can rename the club, remove members, and
> rotate the invite code. You become a member.
>
> If you created the club, you can still delete it.

### iOS

No Settings → Clubs tab. **My Name…** on the Clubs `+` menu
(`ClubsScene`). Rename / Delete-or-Leave / Make Admin on the existing
ellipsis and member swipe. Pull-to-refresh stays `loadNotes()`.

`make build` && `make ios-build`

---

## Phase 4 — Docs

**Commit:** `DOCS Document club auto-publish and owner vs admin`

- `docs/architecture.md`: hook + `isAdmin` vs `isOwner` + empty create sheet
- `README.md`: auto-publish; link this file next to `book-clubs-plan.md`
- This file: Status `implemented` when it lands

Do not rewrite `book-clubs-plan.md`.

---

## Commits

1. [x] `FEAT Add club owner, rename, display name, and admin promote`
2. [x] `FEAT Auto-publish club snapshots after note saves`
3. [x] `FEAT Add club management UI`
4. [x] `DOCS Document club auto-publish and owner vs admin`

## Do not

- Put the publish hook inside `refreshCompiledNotesAfterSave`
- Reload club notes from the save hook
- Hide **New Book Club** when the library is empty
- Transfer `CKShare` ownership
- Author a new test target
