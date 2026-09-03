import MarginsCore

/// The bridge records already carry stable identity properties; making them
/// `Identifiable` lets SwiftUI's `ForEach` use them directly.
extension BookSummary: Identifiable {}

extension ChapterMeta: Identifiable {
    public var id: String { key }
}

extension NoteSearchHit: Identifiable {
    public var id: String { "\(bookId)/\(chapterKey)" }
}

extension CompiledChapter: Identifiable {
    public var id: String { chapterKey }
}
