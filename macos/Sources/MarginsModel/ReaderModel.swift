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

    /// CFI the reader should open at, set when a book is opened with
    /// resume semantics (Enter / double-click / Read). Cleared by any
    /// explicit `open(book:chapter:)` jump and on close.
    public private(set) var resumeCfi: String?

    /// Called (off the main actor) with the book id once the reading
    /// position has settled. Wired at app startup to the library's store.
    public var positionSaver: (@Sendable (String, ReadingPosition) async -> Void)?

    /// Debounce window for position saves; injectable for tests.
    public var positionSaveDebounce: TimeInterval = 0.8
    private var positionSaveTask: Task<Void, Never>?
    private var pendingPosition: (bookId: String, position: ReadingPosition)?

    public init() {}

    public var isOpen: Bool { book != nil }

    /// Opens (or retargets) the reader at a chapter of `book`. An explicit
    /// jump: any pending resume CFI is discarded.
    public func open(book: BookMeta, chapter: ChapterMeta) {
        flushPositionSave()
        self.book = book
        self.chapter = chapter
        resumeCfi = nil
        progress = nil
    }

    /// Arms a CFI resume: the next webview load for this book opens at the
    /// CFI instead of the chapter top. `nil` clears it.
    public func resume(at cfi: String?) {
        resumeCfi = cfi
    }

    public func close() {
        flushPositionSave()
        book = nil
        chapter = nil
        resumeCfi = nil
        progress = nil
        notesVisible = false
        noteBody = ""
        noteBaseline = nil
        notePath = nil
        noteWordCount = nil
        noteUpdatedAt = nil
        notesError = nil
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
        if let href, let book,
           let match = book.chapters.first(where: { $0.href == href }),
           match.key != chapter?.key {
            chapter = match
        }
        schedulePositionSave(cfi: cfi)
    }

    /// Percent complete for the whole book (0–100), interpolated from the
    /// chapter index and the page position within the chapter — being on
    /// page k of m means k/m of the chapter is behind you, so the final
    /// page of the final chapter reaches exactly 100. Display math only;
    /// the persisted value is clamped again by the core.
    public var bookPercent: Double? {
        guard let book, let chapter, let progress, !book.chapters.isEmpty else { return nil }
        let fraction = progress.totalPages > 0
            ? Double(progress.page) / Double(progress.totalPages)
            : 0
        let percent = (Double(chapter.index) + fraction) / Double(book.chapters.count) * 100
        return min(max(percent, 0), 100)
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
        let delay = positionSaveDebounce
        positionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.commitPendingPosition()
        }
    }

    private func commitPendingPosition() {
        guard let pending = pendingPosition else { return }
        pendingPosition = nil
        let saver = positionSaver
        Task.detached {
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

    // MARK: Notes pane state (Part III)

    public private(set) var notesVisible = false
    public private(set) var notesFocusRequest = 0
    public private(set) var readerFocusRequest = 0
    public var noteBody = ""
    public private(set) var noteBaseline: String?
    public private(set) var notePath: String?
    public private(set) var noteWordCount: UInt32?
    public private(set) var noteUpdatedAt: String?
    public private(set) var notesError: String?

    /// The editor differs from what was loaded/saved.
    public var isNoteDirty: Bool {
        noteBody != (noteBaseline ?? "")
    }

    public func toggleNotes() {
        notesVisible.toggle()
        if notesVisible {
            notesFocusRequest += 1
        }
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
    public func noteLoaded(body: String, path: String?, wordCount: UInt32?, updatedAt: String?) {
        noteBody = body
        noteBaseline = body
        notePath = path
        noteWordCount = wordCount
        noteUpdatedAt = updatedAt
        notesError = nil
    }

    /// Marks the current editor content as saved.
    public func noteSaved(path: String, wordCount: UInt32, updatedAt: String?) {
        noteBaseline = noteBody
        notePath = path
        noteWordCount = wordCount
        noteUpdatedAt = updatedAt
        notesError = nil
    }

    public func noteFailed(_ message: String) {
        notesError = message
    }
}
