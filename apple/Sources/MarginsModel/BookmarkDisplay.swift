import Foundation
import MarginsCore

/// Presentation formatting for named location pins, shared by the iOS
/// sheet and the macOS overlay.
public enum BookmarkDisplay {
    /// "1 bookmark" / "3 bookmarks".
    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 bookmark" : "\(count) bookmarks"
    }

    /// The pin's label, or "Chapter · 42%" when untitled.
    public static func title(_ bookmark: Bookmark, chapters: [ChapterMeta]) -> String {
        let trimmed = bookmark.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let chapter = chapters.first { $0.key == bookmark.chapterKey }?.title ?? "Chapter"
        return "\(chapter) · \(Int(bookmark.percent.rounded()))%"
    }

    /// Quiet subtitle: "Ch. 3 · 61%" when the title is a custom label.
    public static func subtitle(_ bookmark: Bookmark, chapters: [ChapterMeta]) -> String {
        let chapter = chapters.first { $0.key == bookmark.chapterKey }
        var parts: [String] = []
        if let chapter {
            parts.append("Ch. \(chapter.index + 1)")
        }
        parts.append("\(Int(bookmark.percent.rounded()))%")
        return parts.joined(separator: " · ")
    }
}
