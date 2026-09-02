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

    public init() {}

    public var isOpen: Bool { book != nil }

    /// Opens (or retargets) the reader at a chapter of `book`.
    public func open(book: BookMeta, chapter: ChapterMeta) {
        self.book = book
        self.chapter = chapter
        progress = nil
    }

    public func close() {
        book = nil
        chapter = nil
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
    /// event: updates the progress footer and follows the chapter when the
    /// renderer moved across a section boundary (e.g. paging past the end
    /// of a chapter with j/k), keeping the notes pane on the right chapter.
    public func relocated(page: Int, totalPages: Int, href: String?) {
        let safeTotal = max(totalPages, 0)
        progress = ReaderProgress(
            page: min(max(page, 1), max(safeTotal, 1)),
            totalPages: safeTotal
        )
        guard let href, let book,
              let match = book.chapters.first(where: { $0.href == href })
        else { return }
        if match.key != chapter?.key {
            chapter = match
        }
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
