import Foundation
import MarginsCore

/// What the chapter-end page shows: the label, the chapter's own title,
/// up to three of its marks' quotes, and a taste of its note. Assembled
/// once, shared by both apps' end pages.
public struct ChapterEndContent: Equatable, Sendable {
    /// "END OF CHAPTER 7" for a numbered chapter, "END OF SECTION" for
    /// headings and matter.
    public let label: String
    public let title: String
    /// Up to three quotes from the chapter's marks, display order.
    public let quotes: [String]
    /// The note's first ~2 lines, or empty when the chapter has no note.
    public let excerpt: String

    /// `ContentsOutline` row → label. Numbered chapters earn the number;
    /// everything else is a section.
    public static func label(for chapter: ChapterMeta, in book: BookMeta) -> String {
        let outline = ContentsOutline.build(from: book.chapters)
        for row in outline.body {
            guard row.chapter.key == chapter.key else { continue }
            if case .chapter(let number) = row.kind {
                return "END OF CHAPTER \(number)"
            }
            return "END OF SECTION"
        }
        // Not in the body outline (front/back matter).
        return "END OF SECTION"
    }

    /// Turn a chapter note's raw body+marks into the page's reading
    /// matter: up to three quotes (display order, truncated) and the
    /// note's first two lines.
    public static func make(
        for chapter: ChapterMeta,
        in book: BookMeta,
        body: String,
        marks: [Mark]
    ) -> ChapterEndContent {
        let quotes = MarkDisplay.sortedForDisplay(marks)
            .map(\.quote)
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { quote in
                quote.count > 200 ? String(quote.prefix(197)) + "…" : quote
            }
        let excerpt =
            body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
        return ChapterEndContent(
            label: label(for: chapter, in: book),
            title: chapter.title,
            quotes: Array(quotes),
            excerpt: excerpt)
    }
}
