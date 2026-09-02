import Foundation
import MarginsCore

/// State of the open reader: which book and chapter are being displayed.
@MainActor
@Observable
public final class ReaderModel {
    public private(set) var book: BookMeta?
    public private(set) var chapter: ChapterMeta?

    public init() {}

    public var isOpen: Bool { book != nil }

    /// Opens (or retargets) the reader at a chapter of `book`.
    public func open(book: BookMeta, chapter: ChapterMeta) {
        self.book = book
        self.chapter = chapter
    }

    public func close() {
        book = nil
        chapter = nil
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
