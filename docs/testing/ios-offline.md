# Testing offline reading on iOS

This document is the acceptance record for offline reading on iOS. The
contract lives in `docs/architecture.md` (local-first sync); the on-disk
layout and sync rules live in `docs/storage.md` ("iOS: local-first
sync"). The library lives on the phone in `Documents/Library`; the iCloud
container's `Documents/Library` is a replica `LibrarySync` keeps in step.

Every row: the expected result within the bound; no spinner without a
label; no alert titled "Something went wrong".

## Simulator fixtures (DEBUG)

| Variable | Effect |
| --- | --- |
| `MARGINS_IMPORT_FIXTURE=/path/to/book.epub` | Import that EPUB into an empty library after activation |
| `MARGINS_SYNC_FIXTURE=<absolute dir>` | Sync against `DirectoryRemote` at that path instead of iCloud |
| `MARGINS_OFFLINE_FIXTURE=1` | Pin connectivity offline (advisory only) |
| `MARGINS_OPEN_FIXTURE=reader` | After import, open the book as a user would |

`MARGINS_SYNC_FIXTURE` makes sync deterministic in the simulator: a book
imported via `MARGINS_IMPORT_FIXTURE` appears under `<dir>/books/<id>/`
within seconds, and relaunching with an empty container pulls everything
the directory holds. `make ios-build` is the compile check.

## Acceptance matrix (device, Airplane Mode where relevant)

| # | Setup | Action | Expect | Bound |
|---|---|---|---|---|
| 1 | Library synced; reboot the phone | Cold launch offline | Grid and reading work from the on-disk library | 2 s |
| 2 | Book present | Files → iCloud Drive → Margins → Remove Download on the book, then offline | Still opens and reads | As online |
| 3 | Airplane Mode on | Import from Files | Readable at once; uploads to the replica when back online | — |
| 4 | Mac edits a note while the phone is offline; the phone edits a different chapter of the same book | Reconnect the phone | Both notes present and the index consistent on both devices | 60 s |
| 5 | Same chapter edited on both devices | Reconnect | Newer edit wins on both; the phone's losing bytes sit under `Application Support/Margins/sync/overwritten/` | 60 s |
| 6 | Book imported on the Mac | Wait for the phone's next pass | Appears in the grid once its EPUB has downloaded | 60 s |
| 7 | Synced book | Delete on the phone | Gone on the Mac after sync | 60 s |
| 8 | Synced book | Delete on the Mac | Gone on the phone after sync | 60 s |
| 9 | Install over the previous build while online | Launch | Library, notes, and reading positions all present | 5 s |
| 10 | Settings → Apple Account → sign out of iCloud | Launch | "iCloud is off — this library is only on this iPhone." row; library intact and fully usable | 2 s |
