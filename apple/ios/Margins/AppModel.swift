import Foundation
import MarginsCore
import MarginsModel
import Observation
import UIKit

/// App-level glue for the iOS target: owns the shared `LibraryModel` and
/// the `LibrarySync` replica. The library is local-first — it lives in
/// `Documents/Library` (Files → On My iPhone → Margins), readable
/// entirely offline; the iCloud container's `Documents/Library` is a
/// replica the sync engine keeps in step, and with no iCloud account the
/// library simply works alone.
@MainActor
@Observable
final class AppModel {
    let library: LibraryModel
    let reader: ReaderModel
    let clubs: ClubModel
    let notebooks = NotebookModel()
    /// Shared search model — the Search tab and the reader's
    /// "Search Library" drive the same query state and see the indexing
    /// pass's progress.
    let search = LibrarySearch()
    /// Kept only for `stagedCopy` (the security-scoped import snapshot).
    let libraryLocation = LibraryLocation()
    let connectivity = Connectivity()

    /// The on-device library root — `Documents/Library`.
    let localRoot: URL
    /// `Application Support/Margins`: the core's config and the sync
    /// state directory.
    let support: URL

    /// nil until the container lookup resolves; false means no iCloud —
    /// sync is off for good this launch.
    private(set) var syncAvailable: Bool?
    var isSyncing: Bool { syncDepth > 0 }
    /// Files the remote has but this device doesn't yet (download
    /// requested). Also drives the "Getting your library" empty state.
    var waitingDownloads = 0
    var syncProblem: String?
    /// Bumped whenever a sync pass changed local files — views key
    /// reloads off it.
    private(set) var syncGeneration = 0
    /// Bumped only when a pass pulled notes for the *open* book — keys the
    /// chapter-note reload so an unrelated pull never clobbers the editor.
    private(set) var noteSyncGeneration = 0

    private var syncDepth = 0
    private var librarySync: LibrarySync?
    private var activationTask: Task<Void, Never>?
    private var syncDebounce: Task<Void, Never>?
    private var syncRetry: Task<Void, Never>?
    private var indexPassRunning = false
    private var indexPassQueued = false

    init() {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        localRoot = documents.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)

        support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margins", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        library = LibraryModel(dataDir: support.path)
        reader = ReaderModel()
        clubs = ClubModel()

        // Wire the reader into the library: removals close the reader, and
        // the debounced position/note savers persist through the store —
        // then kick a sync so edits reach the replica promptly.
        library.reader = reader
        reader.positionSaver = { [weak library, weak self] bookId, position in
            await library?.saveReadingPosition(bookId: bookId, position: position)
            await self?.scheduleSync()
        }
        reader.noteSaver = { [weak library, weak self] bookId, chapterKey, body in
            await library?.saveChapterNoteText(bookId: bookId, chapterKey: chapterKey, body: body)
            await self?.scheduleSync()
        }
    }

    /// Opens the store and starts sync. Idempotent and awaitable: repeat
    /// callers (the DEBUG seams) wait for the first activation instead of
    /// racing a second one.
    func activate() async {
        if let task = activationTask {
            await task.value
            return
        }
        let task = Task { await self.activateOnce() }
        activationTask = task
        await task.value
    }

    private func activateOnce() async {
        // Point the saved root at the local library before the store
        // opens, so `CoreStore` never touches the old container root.
        if var config = try? AppConfig(dataDir: support.path),
            config.libraryRoot != localRoot.path
        {
            try? config.setLibraryRoot(localRoot.path)
        }
        await library.activate()
        if library.libraryRoot != localRoot.path {
            await library.setLibraryRoot(localRoot.path)
        }

        // One-time fold of the old EPUB mirror into the local library.
        try? await Task.detached(priority: .utility) {
            try LibrarySync.seedFromMirror(
                mirrorDirectory: self.support.appendingPathComponent(
                    "epubs", isDirectory: true),
                localRoot: self.localRoot)
        }.value

        // Notes can save before club transport finishes; publish is a
        // no-op while `sync` is still nil. CloudKit must not gate the
        // library grid.
        library.onBookNotesChanged = { [weak clubs, weak self] bookId in
            await clubs?.schedulePublish(bookId: bookId)
            self?.scheduleSync()
        }
        if let store = library.coreStore {
            Task { await clubs.activate(store: store) }
            Task { await notebooks.activate(store: store) }
            search.attach(store: store)
        }

        await library.refresh()
        // Indexing is derived data — don't hold the first sync behind it.
        Task { await self.indexPass() }
        await startSync()
    }

    /// Builds the `LibrarySync`: a `DirectoryRemote` when the DEBUG
    /// fixture is set, else an `ICloudRemote` over the ubiquity
    /// container — looked up off the main thread. No container means no
    /// sync for this launch.
    private func startSync() async {
        let remote: (any SyncRemote)?
        #if DEBUG
        if let fixture = ProcessInfo.processInfo.environment["MARGINS_SYNC_FIXTURE"] {
            remote = DirectoryRemote(root: URL(fileURLWithPath: fixture, isDirectory: true))
        } else {
            remote = await makeICloudRemote()
        }
        #else
        remote = await makeICloudRemote()
        #endif
        guard let remote else {
            syncAvailable = false
            return
        }
        let engine = LibrarySync(
            localRoot: localRoot,
            remote: remote,
            stateDirectory: support.appendingPathComponent("sync", isDirectory: true))
        librarySync = engine
        syncAvailable = true
        await remote.startMonitoring { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }
        await syncNow()
    }

    private func makeICloudRemote() async -> (any SyncRemote)? {
        let container = await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value
        guard let container else { return nil }
        let root = container.appendingPathComponent("Documents/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ICloudRemote(root: root)
    }

    /// Debounced pass: local edits and remote-change notifications land
    /// here. The delay coalesces bursts (position saves, note saves,
    /// metadata updates) into one pass.
    func scheduleSync(after delay: Duration = .seconds(3)) {
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One sync pass: reconcile pulled indexes, refresh the library and
    /// friends when local files changed, and surface download/sync state.
    /// Offline is a no-op — the status line reflects `waitingDownloads`
    /// plus connectivity until a pass actually runs.
    func syncNow() async {
        guard let engine = librarySync else { return }
        guard connectivity.isOnline else { return }

        // Unsaved edits must be on disk before the pass classifies them.
        if reader.isOpen {
            await reader.flushPendingSaves()
        }

        syncDepth += 1
        defer { syncDepth -= 1 }
        guard let report = await engine.sync() else { return }

        waitingDownloads = report.waitingForDownload
        if report.failures.contains(where: { $0.hasPrefix("snapshot:") }) {
            syncProblem = "Couldn't reach iCloud. Margins will try again."
        } else if report.brakeEngaged {
            syncProblem =
                "Some books were missing from iCloud, so this iPhone uploaded them again."
        } else if report.failures.isEmpty {
            syncProblem = nil
        }
        #if DEBUG
        for failure in report.failures where !failure.hasPrefix("snapshot:") {
            print("[sync] \(failure)")
        }
        #endif

        // Pulled note/notebook files can disagree with their derived
        // indexes — rebuild them, and push the fix back out if a rebuild
        // actually wrote.
        var reconciled = false
        if let store = library.coreStore {
            for bookId in report.notesChangedBookIds {
                do {
                    reconciled =
                        try await store.reconcileNotesIndex(bookId: bookId)
                        || reconciled
                } catch {}
            }
            if report.notebooksChanged {
                do {
                    reconciled = try await store.reconcileNotebooksIndex() || reconciled
                } catch {}
            }
        }
        if reconciled { scheduleSync() }

        if report.pulled > 0 || report.deletedLocal > 0 {
            await library.refresh()
            await notebooks.refresh()
            syncGeneration += 1
            // The open book's note reloads only when the pass actually
            // changed its notes — and never over the user's typing.
            if let bookId = reader.book?.id,
                report.notesChangedBookIds.contains(bookId),
                !reader.isNoteDirty
            {
                noteSyncGeneration += 1
            }
            await indexPass()
        }

        // Content iCloud hasn't downloaded yet: retry soon; metadata
        // updates trigger passes too.
        syncRetry?.cancel()
        if report.waitingForDownload > 0 {
            syncRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }

    /// Last-chance pass on backgrounding: flush pending reader saves,
    /// then sync, all inside a background task so the system lets it
    /// finish.
    func syncInBackground() async {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(taskID)
        }
        await reader.flushPendingSaves()
        await syncNow()
        UIApplication.shared.endBackgroundTask(taskID)
    }

    /// One pass over the pending text index: every book with a local
    /// `source.epub` gets built, and the shared `search` model reports
    /// progress. Overlapping calls queue one follow-up. No network —
    /// derived data only.
    func indexPass() async {
        if indexPassRunning {
            indexPassQueued = true
            return
        }
        indexPassRunning = true
        defer {
            indexPassRunning = false
            indexPassQueued = false
        }
        repeat {
            indexPassQueued = false
            await runIndexPass()
        } while indexPassQueued
    }

    private func runIndexPass() async {
        guard let status = await library.textIndexStatus() else { return }
        // Library order, not the status's sorted order.
        let pending = library.books.map(\.id).filter { status.pendingBookIds.contains($0) }
        search.indexStatus = status
        guard !pending.isEmpty else {
            search.indexingProgress = nil
            return
        }
        var done = 0
        search.indexingProgress = (done: 0, total: pending.count)
        for id in pending {
            guard FileManager.default.fileExists(atPath: library.sourceEpubPath(for: id))
            else { continue }
            _ = await library.indexBookText(bookId: id)
            done += 1
            search.indexingProgress = (done: done, total: pending.count)
        }
        search.indexStatus = await library.textIndexStatus()
        search.indexingProgress = nil
    }

    func removeBook(id: String) async {
        await library.removeBook(id: id)
        scheduleSync()
    }

    /// The reader can always try a book whose `source.epub` is on disk —
    /// the library is local-first, so a missing file means it simply
    /// hasn't synced down to this phone yet.
    @discardableResult
    func prepareForReading(bookId: String) async -> Bool {
        guard !FileManager.default.fileExists(atPath: library.sourceEpubPath(for: bookId))
        else { return true }
        let title =
            library.books.first(where: { $0.id == bookId })?.title
            ?? library.selectedBook.flatMap { $0.id == bookId ? $0.title : nil }
            ?? "This book"
        library.errorMessage =
            connectivity.isOnline
            ? "\(title) is still downloading from iCloud."
            : "\(title) isn't on this iPhone yet. Connect to the internet to download it."
        return false
    }

    /// Imports an EPUB handed over by Files/Mail (`onOpenURL`) or any other
    /// security-scoped source: snapshot the bytes under coordination, then
    /// let the core copy it into the library. Returns whether it landed.
    @discardableResult
    func importSecurityScoped(_ picked: URL) async -> Bool {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                picked.stopAccessingSecurityScopedResource()
            }
        }
        do {
            // The opener's grant does not outlive this call; stage a copy
            // the core can read freely (same path as the document picker).
            let staged = try libraryLocation.stagedCopy(of: picked)
            let ids = await library.importEpubs(atPaths: [staged.path])
            if !ids.isEmpty { scheduleSync() }
            await indexPass()
            return true
        } catch {
            library.errorMessage = String(describing: error)
            return false
        }
    }
}
