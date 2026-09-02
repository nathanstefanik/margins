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
}
