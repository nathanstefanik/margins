import Foundation
import MarginsCore

/// Position within the current chapter, as reported by the renderer's
/// `relocated` events. Page counts are the paginated section's own, so they
/// change with typography and window size — they are display state, not
/// persisted data.
public struct ReaderProgress: Equatable, Sendable {
    public var page: Int
    public var totalPages: Int

    public init(page: Int, totalPages: Int) {
        self.page = page
        self.totalPages = totalPages
    }
}

/// State of the open reader: which book and chapter are being displayed.
@MainActor
@Observable
public final class ReaderModel {
    /// Typography preferences applied to the reading surface. Owned here so
    /// the shell and the reader webview drive the same instance; survives
    /// `close()` (chrome state, persisted separately).
    public let preferences = ReaderPreferences()

    public private(set) var book: BookMeta?
    public private(set) var chapter: ChapterMeta?
    public private(set) var progress: ReaderProgress?

    /// Bumped by `open` when the reader is retargeted from outside the
    /// renderer (search hit, sidebar open, passage jump). `relocated`-driven
    /// chapter changes do not touch it: the page already followed those. The
    /// macOS webview observes this to load or display the new target.
    public private(set) var openGeneration = 0

    /// CFI the reader should open at, set when a book is opened with
    /// resume semantics (Enter / double-click / Read). Cleared by any
    /// explicit `open(book:chapter:)` jump and on close.
    public private(set) var resumeCfi: String?

    /// Fragment for the current chapter when an outline row targets a
    /// section other than the chapter's first TOC entry. Cleared whenever
    /// the chapter changes and by `open(book:chapter:)` without a fragment.
    public private(set) var jumpFragmentOverride: String?

    /// Called (off the main actor) with the book id once the reading
    /// position has settled. Wired at app startup to the library's store.
    public var positionSaver: (@Sendable (String, ReadingPosition) async -> Void)?

    /// Debounce window for position saves; injectable for tests.
    public var positionSaveDebounce: TimeInterval = 0.8
    /// Suspends for a debounce window. Injectable so tests can collapse it
    /// and make the save fire on the next main-actor turn instead of racing
    /// the scheduler under heavy parallel test load.
    public var debounceSleep: @Sendable (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(for: .seconds(delay))
    }
    private var positionSaveTask: Task<Void, Never>?
    private var pendingPosition: (bookId: String, position: ReadingPosition)?

    public init() {}

    public var isOpen: Bool { book != nil }

    /// Opens (or retargets) the reader at a chapter of `book`. An explicit
    /// jump: any pending resume CFI is discarded. `fragment` names a section
    /// inside the chapter's file (an outline row); nil anchors at the
    /// chapter's own first TOC entry.
    public func open(book: BookMeta, chapter: ChapterMeta, fragment: String? = nil) {
        flushPositionSave()
        let bookChanged = self.book?.id != book.id
        self.book = book
        self.chapter = chapter
        jumpFragmentOverride = fragment
        resumeCfi = nil
        progress = nil
        currentCfi = nil
        if bookChanged {
            bookmarks = []
        }
        openGeneration += 1
    }

    /// Where the renderer should display the current chapter: the overridden
    /// section anchor when the reader was opened from an outline row, else
    /// the chapter's own `jumpTarget`.
    public var displayTarget: String {
        guard let chapter else { return "" }
        let fragment = jumpFragmentOverride ?? chapter.fragment
        guard let fragment, !fragment.isEmpty else { return chapter.href }
        return "\(chapter.href)#\(fragment)"
    }

    /// Arms a CFI resume: the next webview load for this book opens at the
    /// CFI instead of the chapter top. `nil` clears it.
    public func resume(at cfi: String?) {
        resumeCfi = cfi
    }

    public func close() {
        flushNoteSave()
        flushPositionSave()
        book = nil
        chapter = nil
        resumeCfi = nil
        jumpFragmentOverride = nil
        progress = nil
        notesVisible = false
        noteBody = ""
        noteBaseline = nil
        notePath = nil
        noteWordCount = nil
        noteUpdatedAt = nil
        notesError = nil
        noteSaveStatus = .idle
        bookmarks = []
        currentCfi = nil
    }

    /// Advances to the next chapter, if any; returns it.
    @discardableResult
    public func nextChapter() -> ChapterMeta? {
        moveChapter(1)
    }

    /// Goes back one chapter, if any; returns it.
    @discardableResult
    public func previousChapter() -> ChapterMeta? {
        moveChapter(-1)
    }

    private func moveChapter(_ delta: Int) -> ChapterMeta? {
        guard let book, let chapter,
              let index = book.chapters.firstIndex(where: { $0.key == chapter.key })
        else { return nil }
        let target = index + delta
        guard book.chapters.indices.contains(target) else { return nil }
        flushNoteSave()
        jumpFragmentOverride = nil
        self.chapter = book.chapters[target]
        return self.chapter
    }

    /// Called from the renderer bridge when epub.js reports a relocated
    /// event: updates the progress footer, follows the chapter when the
    /// renderer moved across a section boundary (e.g. paging past the end
    /// of a chapter with j/k), and schedules the debounced position save.
    public func relocated(page: Int, totalPages: Int, href: String?, cfi: String?) {
        let safeTotal = max(totalPages, 0)
        progress = ReaderProgress(
            page: min(max(page, 1), max(safeTotal, 1)),
            totalPages: safeTotal
        )
        if let href, let book, let match = Self.chapter(forHref: href, in: book) {
            if match.key != chapter?.key {
                flushNoteSave()
                jumpFragmentOverride = nil
                chapter = match
            }
        }
        currentCfi = cfi
        schedulePositionSave(cfi: cfi)
    }

    /// epub.js reports section hrefs *manifest-relative* ("wrap0000.html")
    /// while the core's spine hrefs are *zip-root-relative*
    /// ("OEBPS/wrap0000.html"). Match exactly, then by path suffix, then by
    /// basename — mirroring `readerResolveSpineTarget` in reader.js.
    public nonisolated static func chapter(forHref href: String, in book: BookMeta) -> ChapterMeta? {
        let chapters = book.chapters
        if let exact = chapters.first(where: { $0.href == href }) {
            return exact
        }
        if let suffix = chapters.first(where: { $0.href.hasSuffix("/" + href) }) {
            return suffix
        }
        let base = (href as NSString).lastPathComponent
        return chapters.first(where: { ($0.href as NSString).lastPathComponent == base })
    }

    /// The chapter just finished by paging past its last page, or nil.
    /// Requires the previous snapshot to be a different chapter's final
    /// page (with page counts settled, new progress reported) and the new
    /// chapter to be the *immediate successor* — a TOC jump from a last
    /// page to a much later chapter is not finishing the chapter in
    /// between. Succession is by position in `chapters`, not by raw spine
    /// index: the list omits `linear="no"` items, so its indexes can have
    /// gaps. Pure so the views and tests share one definition.
    public nonisolated static func finishedChapter(
        previousKey: String,
        previousProgress: ReaderProgress?,
        newKey: String,
        newProgress: ReaderProgress?,
        chapters: [ChapterMeta]
    ) -> ChapterMeta? {
        guard let previousProgress,
              newProgress != nil,
              previousKey != newKey,
              previousProgress.totalPages > 0,
              previousProgress.page >= previousProgress.totalPages,
              let finishedIndex = chapters.firstIndex(where: { $0.key == previousKey }),
              let newIndex = chapters.firstIndex(where: { $0.key == newKey }),
              newIndex == finishedIndex + 1
        else { return nil }
        return chapters[finishedIndex]
    }

    /// Percent complete for the whole book (0–100), interpolated from the
    /// chapter's position in `book.chapters` and the page position within
    /// the chapter — being on page k of m means k/m of the chapter is
    /// behind you, so the final page of the final chapter reaches exactly
    /// 100. Position in the filtered list, not the raw spine index:
    /// `linear="no"` items leave gaps that would overshoot. Display math
    /// only; the persisted value is clamped again by the core.
    public var bookPercent: Double? {
        guard let book, let chapter, let progress,
              let position = book.chapters.firstIndex(where: { $0.key == chapter.key })
        else { return nil }
        let fraction = progress.totalPages > 0
            ? Double(progress.page) / Double(progress.totalPages)
            : 0
        let percent = (Double(position) + fraction) / Double(book.chapters.count) * 100
        return min(max(percent, 0), 100)
    }

    /// Snapshot of the current page for dropping or restamping a pin.
    /// Before the first `relocated` event there is no page fraction; the
    /// chapter's place in the spine is enough to drop a pin.
    public func currentPosition() -> ReadingPosition? {
        guard let book, let chapter else { return nil }
        let percent: Double
        if let computed = bookPercent {
            percent = computed
        } else if let index = book.chapters.firstIndex(where: { $0.key == chapter.key }),
                  !book.chapters.isEmpty {
            percent = Double(index) / Double(book.chapters.count) * 100
        } else {
            return nil
        }
        return ReadingPosition(
            chapterKey: chapter.key, epubCfi: currentCfi, percent: percent
        )
    }

    /// True when a pin already sits on this page.
    public var pageIsBookmarked: Bool {
        guard let chapter else { return false }
        return bookmarks.contains { $0.isAt(chapterKey: chapter.key, cfi: currentCfi) }
    }

    // MARK: Reading position persistence

    private func schedulePositionSave(cfi: String?) {
        guard let book, let chapter, let percent = bookPercent else { return }
        let position = ReadingPosition(
            chapterKey: chapter.key,
            epubCfi: cfi,
            percent: percent,
            updatedAt: nil
        )
        pendingPosition = (book.id, position)
        positionSaveTask?.cancel()
        let sleep = debounceSleep
        let delay = positionSaveDebounce
        positionSaveTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.commitPendingPosition()
        }
    }

    private func commitPendingPosition() {
        guard let pending = pendingPosition else { return }
        pendingPosition = nil
        // Serialize writes: a flush can commit while an earlier debounce
        // write is still in flight, and an older position must never land
        // after a newer one.
        let previous = positionSaveChain
        let saver = positionSaver
        positionSaveChain = Task {
            await previous?.value
            await saver?(pending.bookId, pending.position)
        }
    }

    /// Cancels the debounce and saves the pending position immediately
    /// (book switches and close/quit paths).
    public func flushPositionSave() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        commitPendingPosition()
    }

    /// `flushPositionSave` for callers that read the position back right
    /// away (e.g. returning from the reader to the detail view): waits for
    /// the serialized write chain so the reload cannot race the save.
    public func flushPositionSaveAndWait() async {
        flushPositionSave()
        await positionSaveChain?.value
    }

    // MARK: Notes pane state (Part III)

    /// How the notes editor's content relates to the last save.
    public enum NoteSaveStatus: Equatable, Sendable {
        case idle
        case edited
        case saving
        case saved
    }

    public private(set) var notesVisible = false
    public private(set) var notesFocusRequest = 0
    public private(set) var readerFocusRequest = 0
    public var noteBody = ""
    public private(set) var noteBaseline: String?
    public private(set) var notePath: String?
    public private(set) var noteWordCount: Int?
    public private(set) var noteUpdatedAt: Date?
    /// The chapter note's quick marks (file order); shown by the notes
    /// pane strip. Mutated by mark edit/delete, never by note reloads of
    /// prose.
    public private(set) var noteMarks: [Mark] = []
    public private(set) var notesError: String?
    public private(set) var noteSaveStatus: NoteSaveStatus = .idle
    /// Named location pins for the open book. Loaded with the book; not
    /// chapter-scoped (unlike `noteMarks`).
    public private(set) var bookmarks: [Bookmark] = []
    /// Last relocated CFI, used when dropping a pin at the current page.
    public private(set) var currentCfi: String?

    /// Called (off the main actor) with book id, chapter key, and body once
    /// the editor content settled. Wired at app startup to the library.
    public var noteSaver: (@Sendable (String, String, String) async -> Void)?

    /// Debounce window after typing stops; injectable for tests.
    public var noteSaveDebounce: TimeInterval = 1.0
    private var noteSaveTask: Task<Void, Never>?
    // Write chains: debounce timers may be cancelled freely, but the file
    // writes themselves must run strictly in commit order.
    private var noteSaveChain: Task<Void, Never>?
    private var positionSaveChain: Task<Void, Never>?

    /// Live word count of the editor content.
    public var liveNoteWordCount: Int {
        noteBody
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    /// Subtle save-state caption; empty while idle so the space stays fixed.
    public var noteStatusText: String {
        switch noteSaveStatus {
        case .idle: ""
        case .edited: "Edited"
        case .saving: "Saving…"
        case .saved: "Saved"
        }
    }

    /// Chapter-contextual notes header: "Ch. 3 · The Market". Pure so tests
    /// can cover missing and long titles; the view truncates display.
    public nonisolated static func noteHeaderText(chapterIndex: Int, chapterTitle: String?) -> String {
        let prefix = "Ch. \(chapterIndex + 1)"
        guard let title = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return prefix }
        return "\(prefix) · \(title)"
    }

    /// The editor differs from what was loaded/saved.
    public var isNoteDirty: Bool {
        noteBody != (noteBaseline ?? "")
    }

    public func toggleNotes() {
        // Closing the pane hands the editor's content to the autosave.
        if notesVisible {
            flushNoteSave()
        }
        notesVisible.toggle()
        if notesVisible {
            notesFocusRequest += 1
        }
    }

    /// Closes the notes pane (Esc's outward cascade); any pending edit is
    /// autosaved first.
    public func closeNotes() {
        guard notesVisible else { return }
        flushNoteSave()
        notesVisible = false
        readerFocusRequest += 1
    }

    public func openNotes() {
        notesVisible = true
        notesFocusRequest += 1
    }

    /// Blurs the notes editor and puts focus back on the book.
    public func requestReaderFocus() {
        readerFocusRequest += 1
    }

    /// Installs a freshly loaded note as the editor baseline.
    public func noteLoaded(
        body: String,
        marks: [Mark] = [],
        path: String?,
        wordCount: Int?,
        updatedAt: Date?
    ) {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        noteBody = body
        noteBaseline = body
        noteMarks = marks
        notePath = path
        noteWordCount = wordCount
        noteUpdatedAt = updatedAt
        notesError = nil
        noteSaveStatus = .idle
    }

    /// Replaces the pane's marks after an edit/delete on disk. The editor
    /// body is untouched: prose and marks are disjoint in the note file.
    public func noteMarksUpdated(_ marks: [Mark]) {
        noteMarks = marks
    }

    public func bookmarksUpdated(_ bookmarks: [Bookmark]) {
        self.bookmarks = Bookmark.sortedForDisplay(bookmarks)
    }

    /// Marks the current editor content as saved. `savedBody` is the text
    /// that was written: if the user kept typing during the save, the
    /// baseline must not swallow the newer edits.
    public func noteSaved(
        path: String,
        wordCount: Int,
        updatedAt: Date?,
        savedBody: String
    ) {
        notePath = path
        noteWordCount = wordCount
        noteUpdatedAt = updatedAt
        notesError = nil
        if noteBody == savedBody {
            noteBaseline = savedBody
            noteSaveStatus = .saved
        } else if noteSaveStatus == .saving {
            noteSaveStatus = .edited
        }
    }

    public func noteFailed(_ message: String) {
        notesError = message
        if noteSaveStatus == .saving {
            noteSaveStatus = .edited
        }
    }

    // MARK: Notes autosave

    /// Called by the view whenever the editor text changes. Debounces the
    /// save so a typing burst produces one write; no-op when clean (e.g.
    /// programmatic loads).
    public func noteEdited() {
        guard isOpen, isNoteDirty else { return }
        noteSaveStatus = .edited
        noteSaveTask?.cancel()
        let sleep = debounceSleep
        let delay = noteSaveDebounce
        noteSaveTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.commitNoteSave()
        }
    }

    /// Cancels the debounce and saves immediately (chapter change, pane
    /// close, reader close, ⌘S).
    public func flushNoteSave() {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        commitNoteSave()
    }

    private func commitNoteSave() {
        guard isNoteDirty, let book, let chapter, let saver = noteSaver else { return }
        let body = noteBody
        noteSaveStatus = .saving
        // Serialize writes: a ⌘S flush can commit while a debounced save is
        // still in flight; the newest snapshot must land last, not first.
        let previous = noteSaveChain
        let bookId = book.id
        let chapterKey = chapter.key
        noteSaveChain = Task {
            await previous?.value
            await saver(bookId, chapterKey, body)
        }
    }
}
