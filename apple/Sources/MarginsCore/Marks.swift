import Foundation

// Parse/serialize the marks section of a chapter note file, and generate
// mark ids. See docs/storage.md for the format; the properties that drive
// every decision here:
//
// - Everything above the `<!-- margins:marks -->` sentinel is the long-form
//   body; the section below it is an append log of blocks.
// - Untouched blocks are re-emitted **byte-identically** — editing or
//   deleting one mark never rewrites unrelated ones.
// - Unparsable content inside the section is preserved verbatim rather than
//   dropped. Losslessness beats tidiness.

public enum Marks {
    /// Starts the marks section. The first occurrence after the frontmatter
    /// wins; a later one inside a mark body is just text.
    public static let sentinel = "<!-- margins:marks -->"

    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    /// 2020-01-01T00:00:00Z; 40 bits of milliseconds reach ~2054.
    private static let epochMilliseconds = 1_577_836_800_000

    // MARK: Ids

    /// Generates a fresh mark id: 10 lowercase Crockford-base32 characters,
    /// time-ordered (millisecond clock since a custom epoch) with 10 bits of
    /// per-millisecond randomness. Callers retry on the (unlikely) collision
    /// with an existing id, so uniqueness holds without coordination.
    public static func newMarkID() -> String {
        let now = Date().timeIntervalSince1970
        let milliseconds = max(Int((now * 1000).rounded(.down)), epochMilliseconds)
            - epochMilliseconds
        var value = UInt64(milliseconds) << 10 | UInt64(randomTenBits(at: now))
        var id = [Character](repeating: "0", count: 10)
        for position in id.indices.reversed() {
            id[position] = alphabet[Int(value & 31)]
            value >>= 5
        }
        return String(id)
    }

    /// Small non-crypto random source for id suffixes: nanos mixed by a
    /// splitmix-style step. Adequate — collisions are retried by callers.
    private static func randomTenBits(at now: TimeInterval) -> UInt32 {
        let nanos = UInt64((now - now.rounded(.down)) * 1_000_000_000)
        var z = (nanos << 13) ^ UInt64(UInt32(bitPattern: ProcessInfo.processInfo.processIdentifier))
        z = (z ^ (z >> 30)) &* 0xbf58_476d_8ce4_e809
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return UInt32((z ^ (z >> 31)) & 0x3ff)
    }

    // MARK: Splitting a note file

    /// Splits post-frontmatter content into the long-form body and the marks
    /// section lines (present when the sentinel appears). The sentinel must
    /// head its own line; the first occurrence wins. The body loses any blank
    /// lines immediately before the sentinel — those are the canonical
    /// separator, re-added on save.
    public static func splitBody(_ content: String) -> (body: String, section: String?) {
        let all = content.lines
        var bodyLines: [Substring] = []
        for (index, line) in all.enumerated() {
            guard line.trimmed == sentinel else {
                bodyLines.append(line)
                continue
            }
            var rest = all[(index + 1)...]
            while let first = rest.first, first.trimmed.isEmpty { rest = rest.dropFirst() }
            while let last = bodyLines.last, last.trimmed.isEmpty { bodyLines.removeLast() }
            return (bodyLines.joined(separator: "\n"), rest.joined(separator: "\n"))
        }
        return (content, nil)
    }

    // MARK: Parsing

    /// Parses a marks section into blocks. Stray text before the first mark
    /// comment and hand-mangled mark comments both come back as `.raw`
    /// blocks. The string may optionally begin with the sentinel line itself
    /// (as a whole file body would); it is skipped.
    public static func parseSection(_ section: String) -> [MarkItem] {
        var items: [MarkItem] = []
        var header: String?
        var content: [Substring] = []
        var raw: [Substring] = []
        var leadingSentinel = true

        func flush() {
            if let comment = header {
                header = nil
                let rawText = joinBlock(comment: comment, content: content)
                if let partial = parseComment(comment),
                   let (quote, body) = splitQuoteBody(content) {
                    let mark = Mark(
                        id: partial.id, cfi: partial.cfi, at: partial.at,
                        percent: partial.percent, quote: quote, body: body
                    )
                    items.append(.mark(mark, raw: rawText))
                } else {
                    items.append(.raw(rawText))
                }
                content.removeAll()
            } else if !raw.isEmpty {
                let trimmed = raw.joined(separator: "\n").trimmed
                if !trimmed.isEmpty { items.append(.raw(String(trimmed))) }
                raw.removeAll()
            }
        }

        for line in section.lines {
            if leadingSentinel {
                leadingSentinel = false
                if line.trimmed == sentinel { continue }
            }
            if let comment = markCommentLine(line) {
                flush()
                header = String(comment)
            } else if header != nil {
                content.append(line)
            } else {
                raw.append(line)
            }
        }
        flush()
        return items
    }

    // MARK: Serializing

    /// Re-renders blocks canonically: one blank line between blocks, section
    /// terminated by a newline. Untouched `.mark` blocks reuse their source
    /// bytes, so unrelated marks keep their exact formatting.
    public static func serialize(_ items: [MarkItem]) -> String {
        let blocks = items.map(\.rawText).joined(separator: "\n\n")
        return "\(sentinel)\n\n\(blocks)\n"
    }

    /// Canonical text of a single mark block (comment + quote + body).
    public static func canonicalBlock(_ mark: Mark) -> String {
        var block = "\(commentPrefix(mark)) -->\n"
        if !mark.quote.isEmpty {
            for line in mark.quote.lines {
                block += "> \(line)\n"
            }
        }
        if !mark.body.isEmpty {
            block += "\n\(mark.body)\n"
        }
        return String(block.trimmedEnd)
    }

    // MARK: Editing

    /// Appends a canonical block for `mark`, keeping everything else
    /// byte-identical.
    public static func append(_ mark: Mark, to items: inout [MarkItem]) {
        items.append(.mark(mark, raw: canonicalBlock(mark)))
    }

    /// Replaces the block with `mark.id`, re-rendering it canonically; every
    /// other block keeps its source bytes. Returns false when the id is
    /// unknown.
    @discardableResult
    public static func update(_ mark: Mark, in items: inout [MarkItem]) -> Bool {
        for index in items.indices {
            guard case let .mark(existing, _) = items[index], existing.id == mark.id else {
                continue
            }
            items[index] = .mark(mark, raw: canonicalBlock(mark))
            return true
        }
        return false
    }

    /// Removes the block with `id`; every other block keeps its source bytes.
    /// Returns false when the id is unknown.
    @discardableResult
    public static func delete(id: String, from items: inout [MarkItem]) -> Bool {
        let before = items.count
        items.removeAll { item in
            guard case let .mark(mark, _) = item else { return false }
            return mark.id == id
        }
        return items.count != before
    }

    /// The `Mark` records of a section, disk order preserved (callers sort
    /// when they need reading order).
    public static func marks(_ items: [MarkItem]) -> [Mark] {
        items.compactMap { item in
            guard case let .mark(mark, _) = item else { return nil }
            return mark
        }
    }

    /// Reading order for display: percent ascending, then CFI, then id;
    /// marks without a percent go last.
    public static func sortedByReadingOrder(_ marks: [Mark]) -> [Mark] {
        marks.sorted { a, b in
            let left = a.percent ?? .greatestFiniteMagnitude
            let right = b.percent ?? .greatestFiniteMagnitude
            if left != right { return left < right }
            if a.cfi != b.cfi { return isOrderedBefore(a.cfi, b.cfi) }
            return a.id < b.id
        }
    }

    /// `Option<String>`'s ordering: absent sorts before present.
    private static func isOrderedBefore(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (a?, b?): return a < b
        }
    }

    // MARK: Internals

    private static func joinBlock(comment: String, content: [Substring]) -> String {
        var text = comment
        for line in content {
            text += "\n\(line)"
        }
        return String(text.trimmedEnd)
    }

    /// Returns the comment text when `line` starts a mark block —
    /// `<!-- margins:mark ... -->`. The sentinel (`margins:marks`) does not
    /// match: the character after `mark` must be whitespace.
    private static func markCommentLine(_ line: Substring) -> Substring? {
        let trimmed = line.trimmed
        guard let afterOpen = trimmed.strippingPrefix("<!--")?.trimmedStart,
              let attributes = afterOpen.strippingPrefix("margins:mark"),
              let first = attributes.first, first.isWhitespace,
              trimmed.hasSuffix("-->")
        else { return nil }
        return trimmed
    }

    private struct PartialMark {
        var id: String
        var cfi: String?
        var at: Date
        var percent: Double?
    }

    /// Parses `<!-- margins:mark id=... cfi="..." at=... percent=... -->`.
    /// Missing/unparsable `id` or `at` fails the whole block (it is kept as
    /// `.raw`); a malformed `cfi`/`percent` degrades gracefully.
    private static func parseComment(_ comment: String) -> PartialMark? {
        guard let inner = comment.trimmed.strippingPrefix("<!--")?.strippingSuffix("-->")?.trimmed,
              let attributes = inner.strippingPrefix("margins:mark")?.trimmed
        else { return nil }

        var id: String?
        var cfi: String?
        var at: Date?
        var percent: Double?

        for (key, value) in parseAttributes(attributes) {
            switch key {
            case "id": id = value
            case "cfi": cfi = value
            case "at": at = RFC3339.date(from: value)
            case "percent": percent = Double(value)
            default: break
            }
        }

        guard let id, let at else { return nil }
        return PartialMark(
            id: id, cfi: cfi.flatMap { $0.isEmpty ? nil : $0 }, at: at, percent: percent
        )
    }

    /// Whitespace-separated `key=value` tokens; values may be double-quoted.
    private static func parseAttributes(_ attributes: Substring) -> [(String, String)] {
        var pairs: [(String, String)] = []
        var index = attributes.startIndex

        while index < attributes.endIndex {
            if attributes[index].isWhitespace {
                index = attributes.index(after: index)
                continue
            }
            var key = ""
            while index < attributes.endIndex,
                  attributes[index] != "=", !attributes[index].isWhitespace {
                key.append(attributes[index])
                index = attributes.index(after: index)
            }
            guard index < attributes.endIndex, attributes[index] == "=" else {
                // Bare token — skip to the next whitespace boundary.
                while index < attributes.endIndex, !attributes[index].isWhitespace {
                    index = attributes.index(after: index)
                }
                continue
            }
            index = attributes.index(after: index) // '='

            var value = ""
            if index < attributes.endIndex, attributes[index] == "\"" {
                index = attributes.index(after: index)
                while index < attributes.endIndex {
                    let character = attributes[index]
                    index = attributes.index(after: index)
                    if character == "\"" { break }
                    value.append(character)
                }
            } else {
                while index < attributes.endIndex, !attributes[index].isWhitespace {
                    value.append(attributes[index])
                    index = attributes.index(after: index)
                }
            }
            pairs.append((key, value))
        }
        return pairs
    }

    /// Splits block content into the leading `>`-blockquote (the quoted
    /// selection) and the remaining body. A block with neither is invalid
    /// (`nil`) — a mark comment with nothing under it carries no information.
    private static func splitQuoteBody(_ content: [Substring]) -> (quote: String, body: String)? {
        var quoteLines: [Substring] = []
        var rest = content[...]
        while let line = rest.first, let quoted = line.trimmedStart.strippingPrefix(">") {
            quoteLines.append(quoted.strippingPrefix(" ") ?? quoted)
            rest = rest.dropFirst()
        }
        // Skip blank lines between quote and body.
        while let line = rest.first, line.trimmed.isEmpty {
            rest = rest.dropFirst()
        }
        let body = String(rest.joined(separator: "\n").trimmed)
        let quote = quoteLines.joined(separator: "\n")
        if quote.isEmpty, body.isEmpty { return nil }
        return (quote, body)
    }

    private static func commentPrefix(_ mark: Mark) -> String {
        var prefix = "<!-- margins:mark id=\(mark.id) cfi=\"\(mark.cfi ?? "")\""
            + " at=\(RFC3339.secondsString(from: mark.at))"
        if let percent = mark.percent {
            prefix += String(format: " percent=%.1f", percent)
        }
        return prefix
    }
}

/// A block of the marks section: a parsed mark keeping its exact source
/// bytes, or unparsable lines preserved verbatim.
public enum MarkItem: Sendable, Equatable {
    case mark(Mark, raw: String)
    case raw(String)

    /// The block's bytes as they belong in the file.
    public var rawText: String {
        switch self {
        case let .mark(_, raw): return raw
        case let .raw(text): return text
        }
    }
}
