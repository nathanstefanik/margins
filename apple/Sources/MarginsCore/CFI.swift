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
        guard
            let inner = trimmed.strippingPrefix("epubcfi(")?
                .strippingSuffix(")")
        else { return nil }

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
            let aLow = min(aStart, aEnd)
            let aHigh = max(aStart, aEnd)
            let bLow = min(bStart, bEnd)
            let bHigh = max(bStart, bEnd)
            return aLow <= bHigh && bLow <= aHigh
        }
        guard a.element.count != b.element.count else { return false }
        let (shorter, longer) =
            a.element.count < b.element.count
            ? (a.element, b.element) : (b.element, a.element)
        return longer.starts(with: shorter)
    }

    public static func comparePoints(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parsePoint(lhs), let right = parsePoint(rhs) else {
            return nil
        }
        if left.base != right.base { return compareSteps(left.base, right.base) }
        if left.path != right.path { return compareSteps(left.path, right.path) }
        if left.offset != right.offset {
            return left.offset < right.offset ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private struct Point {
        var base: [Int]
        var path: [Int]
        var offset: Int
    }

    private static func parsePoint(_ raw: String) -> Point? {
        let trimmed = raw.trimmed
        guard
            let inner = trimmed.strippingPrefix("epubcfi(")?
                .strippingSuffix(")"),
            !inner.isEmpty
        else { return nil }

        var inAssertion = false
        var bang: String.Index?
        var index = inner.startIndex
        while index < inner.endIndex {
            let character = inner[index]
            if inAssertion {
                if character == "^" {
                    index = inner.index(after: index)
                    guard index < inner.endIndex else { return nil }
                } else if character == "]" {
                    inAssertion = false
                }
            } else {
                switch character {
                case "^":
                    index = inner.index(after: index)
                    guard index < inner.endIndex else { return nil }
                case "[":
                    inAssertion = true
                case "]":
                    return nil
                case "!":
                    guard bang == nil else { return nil }
                    bang = index
                case ",":
                    return nil
                default:
                    break
                }
            }
            index = inner.index(after: index)
        }
        guard !inAssertion else { return nil }

        let baseText: Substring
        let pathText: Substring
        if let bang {
            baseText = inner[..<bang]
            pathText = inner[inner.index(after: bang)...]
        } else {
            baseText = inner[...]
            pathText = inner[inner.endIndex...]
        }
        guard let base = parsePointSteps(baseText, allowTerminal: bang == nil)
        else { return nil }
        var path: [Int] = []
        var offset = base.offset
        if bang != nil {
            guard let local = parsePointSteps(pathText, allowTerminal: true)
            else { return nil }
            path = local.steps
            offset = local.offset
        }
        return Point(base: base.steps, path: path, offset: offset)
    }

    private static func parsePointSteps(
        _ text: Substring, allowTerminal: Bool
    ) -> (steps: [Int], offset: Int)? {
        guard text.first == "/" else { return nil }
        let body = text[text.index(after: text.startIndex)...]
        guard !body.isEmpty else { return nil }
        var stepTexts: [Substring] = []
        var inAssertion = false
        var start = body.startIndex
        var index = start
        while index < body.endIndex {
            let character = body[index]
            if inAssertion {
                if character == "^" {
                    index = body.index(after: index)
                    guard index < body.endIndex else { return nil }
                } else if character == "]" {
                    inAssertion = false
                }
            } else if character == "^" {
                index = body.index(after: index)
                guard index < body.endIndex else { return nil }
            } else if character == "[" {
                inAssertion = true
            } else if character == "/" {
                stepTexts.append(body[start..<index])
                index = body.index(after: index)
                start = index
                continue
            }
            index = body.index(after: index)
        }
        guard !inAssertion else { return nil }
        stepTexts.append(body[start..<body.endIndex])

        var steps: [Int] = []
        var offset = 0
        for (stepIndex, stepText) in stepTexts.enumerated() {
            let terminal = allowTerminal && stepIndex == stepTexts.count - 1
            guard let parsed = parsePointStep(stepText, terminal: terminal) else {
                return nil
            }
            steps.append(parsed.step)
            if let terminalOffset = parsed.offset {
                offset = terminalOffset
            }
        }
        return (steps, offset)
    }

    private static func parsePointStep(
        _ raw: Substring, terminal: Bool
    ) -> (step: Int, offset: Int?)? {
        var index = raw.startIndex
        let digitsStart = index
        while index < raw.endIndex, raw[index] >= "0", raw[index] <= "9" {
            index = raw.index(after: index)
        }
        guard digitsStart < index, let step = Int(raw[digitsStart..<index]), step > 0
        else { return nil }

        var offset: Int?
        guard consumeAssertions(raw, at: &index) else { return nil }
        if index < raw.endIndex, raw[index] == ":" {
            guard terminal else { return nil }
            index = raw.index(after: index)
            let offsetStart = index
            while index < raw.endIndex, raw[index] >= "0", raw[index] <= "9" {
                index = raw.index(after: index)
            }
            guard offsetStart < index, let value = Int(raw[offsetStart..<index])
            else { return nil }
            offset = value
            guard consumeAssertions(raw, at: &index) else { return nil }
        }

        if index < raw.endIndex, raw[index] == ";" {
            guard terminal else { return nil }
            guard raw[index...] == ";s=a" || raw[index...] == ";s=b" else {
                return nil
            }
            index = raw.endIndex
        }

        guard index == raw.endIndex else { return nil }
        return (step, offset)
    }

    private static func consumeAssertions(
        _ raw: Substring, at index: inout Substring.Index
    ) -> Bool {
        while index < raw.endIndex, raw[index] == "[" {
            index = raw.index(after: index)
            var closed = false
            while index < raw.endIndex {
                let character = raw[index]
                if character == "^" {
                    index = raw.index(after: index)
                    guard index < raw.endIndex else { return false }
                } else if character == "[" {
                    return false
                } else if character == "]" {
                    closed = true
                    index = raw.index(after: index)
                    break
                }
                index = raw.index(after: index)
            }
            guard closed else { return false }
        }
        return true
    }

    private static func compareSteps(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
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
