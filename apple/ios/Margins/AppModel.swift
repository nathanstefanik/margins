import Foundation
import Observation
import MarginsCore
import MarginsModel

/// App-level glue for the iOS target: resolves the library location once
/// per launch (ubiquity container paths change between installs) and owns
/// the shared `LibraryModel`.
@MainActor
@Observable
final class AppModel {
    let library: LibraryModel
    let reader: ReaderModel
    let clubs: ClubModel
    let libraryLocation: LibraryLocation
    let connectivity = Connectivity()
    /// Where the library root resolved to this launch; the scene surfaces
    /// the reason whenever the runtime fallback kicked in.
    let locationSource: LibraryLocation.Source

    var locationNotice: String?
    /// True while an evicted `source.epub` is downloading; the library
    /// scene shows a quiet overlay so Continue reading is not a blank fail.
    var isMaterializing = false
    private(set) var pendingDownloads = 0
    private(set) var downloadGeneration = 0

    private var materializationTask: Task<String, Error>?
    private var downloadPassRunning = false
    private var downloadPassQueued = false

    init() {
        let location: LibraryLocation
        #if DEBUG
        if ProcessInfo.processInfo.environment["MARGINS_EVICT_FIXTURE"] != nil {
            let documents = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
            FileStore.overrideContainerProvider { documents }
            location = LibraryLocation(containerProvider: { documents })
        } else {
            location = LibraryLocation()
        }
        #else
        location = LibraryLocation()
        #endif
        libraryLocation = location
        locationSource = location.resolve()

        // The core's config.json (which remembers the library root) lives
        // in Application Support; the library itself goes in the resolved
        // location below.
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margins", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        library = LibraryModel(dataDir: support.path)
        reader = ReaderModel()
        clubs = ClubModel()

        // Wire the reader into the library: removals close the reader, and
        // the debounced position/note savers persist through the store.
        library.reader = reader
        reader.positionSaver = { [weak library] bookId, position in
            await library?.saveReadingPosition(bookId: bookId, position: position)
        }
        reader.noteSaver = { [weak library] bookId, chapterKey, body in
            await library?.saveChapterNoteText(bookId: bookId, chapterKey: chapterKey, body: body)
        }
    }

    /// Opens the store, then pins the core to the freshly resolved root.
    /// Runs every launch: container paths are not stable across installs,
    /// and the saved root must never go stale.
    func activate() async {
        await library.activate()
        let root: String
        switch locationSource {
        case .iCloudDocuments(let path):
            root = path
            locationNotice = nil
        case .localDocuments(let path):
            root = path
            locationNotice =
                "iCloud unavailable — the library is stored locally under On My iPhone."
        }
        #if DEBUG
        print("[library] resolved \(locationSource)")
        #endif
        if library.libraryRoot != root {
            await library.setLibraryRoot(root)
        }
        // Clubs reuse the library's store actor; data dir is app-support,
        // so club state never lands in the synced library folder.
        if let store = library.coreStore {
            await clubs.activate(store: store)
        }
        library.onBookNotesChanged = { [weak clubs] bookId in
            await clubs?.schedulePublish(bookId: bookId)
        }
        await downloadPass()
    }

    /// Asks iCloud for every placeholder under the library root, then
    /// polls until the tree is current, the count stops moving, or the
    /// bound elapses. Overlapping calls queue one follow-up pass; offline
    /// is a no-op.
    func downloadPass() async {
        guard connectivity.isOnline else { return }
        if downloadPassRunning {
            downloadPassQueued = true
            return
        }
        downloadPassRunning = true
        defer {
            downloadPassRunning = false
            downloadPassQueued = false
            pendingDownloads = 0
        }
        repeat {
            downloadPassQueued = false
            await runDownloadPass()
        } while downloadPassQueued && connectivity.isOnline
    }

    private func runDownloadPass() async {
        let root = library.libraryRoot
        guard !root.isEmpty else { return }

        await Task.detached(priority: .utility) {
            _ = LibraryLocation.requestDownloads(under: root)
        }.value

        var count = await Task.detached(priority: .utility) {
            LibraryLocation.placeholderCount(under: root)
        }.value
        pendingDownloads = count
        if count == 0 { return }

        var last = count
        var unchanged = 0
        let deadline = ContinuousClock.now + .seconds(120)
        while count > 0 {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled || !connectivity.isOnline { return }
            if ContinuousClock.now >= deadline { return }
            count = await Task.detached(priority: .utility) {
                LibraryLocation.placeholderCount(under: root)
            }.value
            pendingDownloads = count
            if count < last {
                await library.refresh()
                downloadGeneration += 1
                if count == 0 { return }
                unchanged = 0
            } else {
                unchanged += 1
                if unchanged >= 5 { return }
            }
            last = count
        }
    }

    /// True when `books/{id}/source.epub` is on this device. Cheap enough
    /// to call per grid cell; the badge means the EPUB is not local.
    func isReadableOffline(bookId: String) -> Bool {
        LibraryLocation.availability(of: library.sourceEpubPath(for: bookId)) == .local
    }

    func cancelMaterialization() {
        materializationTask?.cancel()
    }

    /// Ensures `books/{id}/source.epub` is on disk before the reader
    /// fetches bytes. Local and missing files pass through (the core owns
    /// the missing-file error). An evicted item either fails immediately
    /// when offline or downloads, bounded and cancellable.
    @discardableResult
    func prepareForReading(bookId: String) async -> Bool {
        let path = library.sourceEpubPath(for: bookId)
        switch LibraryLocation.availability(of: path) {
        case .local, .missing:
            return true
        case .evicted:
            break
        }
        LibraryLocation.requestDownload(path)
        if !connectivity.isOnline {
            let title = library.books.first(where: { $0.id == bookId })?.title
                ?? library.selectedBook.flatMap { $0.id == bookId ? $0.title : nil }
                ?? "This book"
            library.errorMessage =
                "\(title) isn't downloaded to this iPhone. Connect to the internet to download it."
            return false
        }
        materializationTask?.cancel()
        isMaterializing = true
        let task = Task {
            try await libraryLocation.materializedPath(for: path, pollLimit: 600)
        }
        materializationTask = task
        defer {
            isMaterializing = false
            if materializationTask == task {
                materializationTask = nil
            }
        }
        do {
            _ = try await task.value
            return true
        } catch is CancellationError {
            return false
        } catch {
            library.errorMessage = error.localizedDescription
            return false
        }
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
            await library.importEpubs(atPaths: [staged.path])
            return true
        } catch {
            library.errorMessage = String(describing: error)
            return false
        }
    }
}
