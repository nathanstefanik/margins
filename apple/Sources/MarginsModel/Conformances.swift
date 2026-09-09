import MarginsCore

/// The bridge records already carry stable identity properties; making them
/// `Identifiable` lets SwiftUI's `ForEach` use them directly.
extension BookSummary: Identifiable {}

extension ChapterMeta: Identifiable {
    public var id: String { key }

    /// Where the reader should land for this chapter: the chapter's TOC
    /// anchor when the book named one, otherwise the top of its file.
    /// `href` itself stays a pure path, because relocation events are
    /// matched against it.
    public var jumpTarget: String {
        guard let fragment, !fragment.isEmpty else { return href }
        return "\(href)#\(fragment)"
    }
}

extension NoteSearchHit: Identifiable {
    public var id: String { "\(bookId)/\(chapterKey)" }
}

extension CompiledChapter: Identifiable {
    public var id: String { chapterKey }
}
