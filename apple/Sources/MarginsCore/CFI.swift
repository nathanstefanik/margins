import Foundation

// A partial EPUB CFI reader for one job: deciding whether two marks from the
// same book point at the same passage, so the club view can render one quote
// with every member's thought stacked under it.
//
// This is deliberately not a full CFI implementation. It reads element paths
// (dropping assertions), text offsets, and range forms; anything else fails
// to `nil`, and the caller falls back to clustering on the quoted text. That
// is enough for passage clustering and nothing else.
public struct CFIRange: Sendable, Equatable, Hashable {
    /// Normalized element path, e.g. `[6, 14, 4, 2, 10, 1]` — the parent
    /// path plus the range step's own index.
    public var element: [Int]
    /// Text offsets when the location carries them; `nil` for element-level
    /// selections that cover a whole element.
    public var startOffset: Int?
    public var endOffset: Int?

    public init(element: [Int], startOffset: Int? = nil, endOffset: Int? = nil) {
        self.element = element
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public enum CFI {
    /// Parses `epubcfi(...)` into an element path and offsets. Accepts a
    /// point (`/6/4!/4/2/1:0`), an element selection without offsets
    /// (`/6/4!/4/2`), and a range with a parent path
    /// (`/6/14!/4/2/10,/1:0,/1:42`). Returns `nil` for anything else,
    /// including ranges spanning different elements.
    public static func parse(_ raw: String) -> CFIRange? {
        let trimmed = raw.trimmed
        guard let inner = trimmed.strippingPrefix("epubcfi(")?
            .strippingSuffix(")") else { return nil }

        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        switch parts.count {
        case 1:
            guard let (element, offset) = parsePath(parts[0]) else { return nil }
            return CFIRange(element: element, startOffset: offset, endOffset: offset)
        case 3:
            guard let (parent, _) = parsePath(parts[0]),
                  let (startPath, startOffset) = parsePath(parts[1]),
                  let (endPath, endOffset) = parsePath(parts[2]),
                  !startPath.isEmpty, !endPath.isEmpty,
                  startPath.dropLast() == endPath.dropLast()
            else { return nil }
            return CFIRange(
                element: parent + startPath, startOffset: startOffset, endOffset: endOffset
            )
        default:
            return nil
        }
    }

    /// True when two locations select overlapping content: the same element
    /// with overlapping offset ranges, an element-level selection in the same
    /// element, or an element path that contains the other (one path is a
    /// strict prefix of the other).
    public static func overlaps(_ a: CFIRange, _ b: CFIRange) -> Bool {
        if a.element == b.element {
            guard let aStart = a.startOffset, let aEnd = a.endOffset,
                  let bStart = b.startOffset, let bEnd = b.endOffset
            else { return true }
            let aLow = min(aStart, aEnd), aHigh = max(aStart, aEnd)
            let bLow = min(bStart, bEnd), bHigh = max(bStart, bEnd)
            return aLow <= bHigh && bLow <= aHigh
        }
        guard a.element.count != b.element.count else { return false }
        let (shorter, longer) = a.element.count < b.element.count
            ? (a.element, b.element) : (b.element, a.element)
        return longer.starts(with: shorter)
    }

    /// Splits a path like `/6/14!/4/2[body01]/10:3` into
    /// `([6, 14, 4, 2, 10], 3)`. `nil` on an empty or non-numeric path; an
    /// offset is only accepted on the final step.
    private static func parsePath(_ raw: String) -> (element: [Int], offset: Int?)? {
        let components = raw.split(whereSeparator: { $0 == "/" || $0 == "!" })
        guard !components.isEmpty else { return nil }

        var element: [Int] = []
        var offset: Int?
        for (index, component) in components.enumerated() {
            var step = component
            if let bracket = step.firstIndex(of: "[") {
                step = step[..<bracket]
            }
            if let colon = step.firstIndex(of: ":") {
                guard index == components.count - 1 else { return nil }
                let offsetText = step[step.index(after: colon)...]
                guard let parsed = Int(offsetText), !offsetText.isEmpty else { return nil }
                offset = parsed
                step = step[..<colon]
            }
            guard !step.isEmpty, let number = Int(step) else { return nil }
            element.append(number)
        }
        return (element, offset)
    }
}
