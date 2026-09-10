import Foundation
import MarginsCore

/// A titled block of palette results: navigation targets ("Chapters") above
/// content hits ("Notes").
public struct SearchSection: Equatable, Sendable {
    public var title: String
    public var hits: [NoteSearchHit]

    public init(title: String, hits: [NoteSearchHit]) {
        self.title = title
        self.hits = hits
    }
}

/// Pure helpers for organizing palette results and rendering the core's
/// match ranges — both unit-testable without UI.
public enum SearchResultsOrganizer {
    /// Splits hits into sections: navigation targets (chapter titles, book
    /// targets) first, then note-content hits, preserving each list's
    /// relevance order.
    public static func sections(for hits: [NoteSearchHit]) -> [SearchSection] {
        var chapters: [NoteSearchHit] = []
        var notes: [NoteSearchHit] = []
        for hit in hits {
            switch hit.kind {
            case .chapterTitle, .bookTarget:
                chapters.append(hit)
            case .noteContent:
                notes.append(hit)
            }
        }
        var sections: [SearchSection] = []
        if !chapters.isEmpty {
            sections.append(SearchSection(title: "Chapters", hits: chapters))
        }
        if !notes.isEmpty {
            sections.append(SearchSection(title: "Notes", hits: notes))
        }
        return sections
    }

    /// The display order the palette navigates: sections flattened.
    public static func flatOrder(for hits: [NoteSearchHit]) -> [NoteSearchHit] {
        sections(for: hits).flatMap(\.hits)
    }
}

/// Renders core match ranges (UTF-16, half-open) as attributed text so the
/// UI never re-runs the matcher. Pure Foundation: the highlight container
/// carries `.inlinePresentationIntent`, which views extend with styling.
public enum SearchHighlighter {
    /// Splits `text` into base and highlighted runs exactly along the
    /// provided ranges. Overlapping ranges are merged defensively.
    public static func attributed(
        _ text: String,
        ranges: [MatchRange],
        highlight: AttributeContainer,
        base: AttributeContainer = .init()
    ) -> AttributedString {
        var out = AttributedString()
        let total16 = text.utf16.count
        var cursor = 0

        func append(_ start16: Int, _ end16: Int, attrs: AttributeContainer?) {
            let clampedStart = min(max(start16, 0), total16)
            let clampedEnd = min(max(end16, clampedStart), total16)
            guard clampedEnd > clampedStart else { return }
            let start = String.Index(utf16Offset: clampedStart, in: text)
            let end = String.Index(utf16Offset: clampedEnd, in: text)
            var piece = AttributedString(text[start..<end])
            if let attrs {
                piece.mergeAttributes(attrs)
            }
            out += piece
        }

        for range in ranges.sorted(by: { $0.start < $1.start }) {
            let start = Int(range.start)
            let end = Int(range.end)
            guard start >= cursor else { continue } // defensive: skip overlaps
            append(cursor, start, attrs: nil)
            append(start, end, attrs: highlight)
            cursor = end
        }
        append(cursor, total16, attrs: nil)
        return out
    }

    /// The standard matched-text treatment: bold (strong emphasis).
    public static var highlightIntent: AttributeContainer {
        var container = AttributeContainer()
        container.inlinePresentationIntent = .stronglyEmphasized
        return container
    }
}
