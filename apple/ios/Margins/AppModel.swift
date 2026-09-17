import Foundation
import Observation
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
    /// Where the library root resolved to this launch; the scene surfaces
    /// the reason whenever the runtime fallback kicked in.
    let locationSource: LibraryLocation.Source

    var locationNotice: String?
    /// True while an evicted `source.epub` is downloading; the library
    /// scene shows a quiet overlay so Continue reading is not a blank fail.
    var isMaterializing = false

    init() {
        let location = LibraryLocation()
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
    }

    /// Ensures `books/{id}/source.epub` is on disk before the reader
    /// fetches bytes. Local files pass through; an evicted iCloud item
    /// downloads (bounded) and surfaces a timeout as `library.errorMessage`.
    @discardableResult
    func prepareForReading(bookId: String) async -> Bool {
        let path = library.sourceEpubPath(for: bookId)
        let url = URL(fileURLWithPath: path)
        let evicted = LibraryLocation.hasEvictedPlaceholder(for: url)
        if evicted {
            isMaterializing = true
        }
        defer { isMaterializing = false }
        do {
            _ = try await libraryLocation.materializedPath(for: path)
            return true
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
