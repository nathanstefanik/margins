import MarginsCore

/// The bridge records already carry stable identity properties; making them
/// `Identifiable` lets SwiftUI's `ForEach` use them directly.
extension BookSummary: Identifiable {}

extension ChapterMeta: Identifiable {
    public var id: String { key }
}
