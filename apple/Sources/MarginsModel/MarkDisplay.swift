import Foundation
import MarginsCore

/// Presentation formatting for quick marks, shared by the notes pane strip
/// and the compiled notes page. Pure so MarginsTests can cover it without
/// UI; mirrors the core's reading-order rule (percent, then CFI, then id;
/// marks without a percent last).
public enum MarkDisplay {
    /// Quiet attribution line: "38.2% · Sep 5, 2026" (date only when the
    /// mark carries no percent).
    public static func attribution(percent: Double?, at: String?) -> String {
        var parts: [String] = []
        if let percent {
            parts.append(String(format: "%.1f%%", percent))
        }
        if let date = at.flatMap(LibraryModel.parseRFC3339) {
            parts.append(LibraryModel.dateText(date))
        }
        return parts.joined(separator: " · ")
    }

    /// "1 mark" / "3 marks".
    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 mark" : "\(count) marks"
    }

    /// Marks in reading order for display; disk order is append order.
    public static func sortedForDisplay(_ marks: [Mark]) -> [Mark] {
        marks.sorted { a, b in
            let pa = a.percent ?? Double.greatestFiniteMagnitude
            let pb = b.percent ?? Double.greatestFiniteMagnitude
            if pa != pb { return pa < pb }
            if a.cfi != b.cfi { return (a.cfi ?? "") < (b.cfi ?? "") }
            return a.id < b.id
        }
    }
}
