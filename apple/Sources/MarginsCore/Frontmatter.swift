import Foundation

// The YAML codec for a chapter note's frontmatter block (docs/storage.md).
//
// Note frontmatter is a flat map of scalars and nothing else, so this is a
// hand-written emitter and line parser rather than a YAML library. What it
// has to reproduce is `serde_yaml` 0.9's output, because the Swift core must
// write files the legacy core wrote and read the ones already on disk: keys in
// declaration order, `key: value` with one space, optional fields omitted
// rather than nulled, and a plain scalar wherever YAML would read it back as
// the same string.
enum Frontmatter {
    // MARK: Emitting

    /// Renders the frontmatter block's body — the lines between the `---`
    /// fences, with a trailing newline.
    static func encode(_ frontmatter: NoteFrontmatter) -> String {
        var lines: [String] = [
            "book_id: \(scalar(frontmatter.bookId))",
            "chapter_key: \(scalar(frontmatter.chapterKey))",
            "chapter_index: \(frontmatter.chapterIndex)",
            "chapter_title: \(scalar(frontmatter.chapterTitle))",
            "chapter_href: \(scalar(frontmatter.chapterHref))",
        ]
        if let cfi = frontmatter.epubCfi {
            lines.append("epub_cfi: \(scalar(cfi))")
        }
        lines.append("kind: \(scalar(frontmatter.kind))")
        lines.append("word_count: \(frontmatter.wordCount)")
        if let created = frontmatter.createdAt {
            lines.append("created_at: \(RFC3339.string(from: created))")
        }
        if let updated = frontmatter.updatedAt {
            lines.append("updated_at: \(RFC3339.string(from: updated))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A string as a YAML scalar: plain when it reads back unchanged,
    /// single-quoted otherwise.
    ///
    /// The one departure from `serde_yaml` is a string containing a line
    /// break or a control character, which it renders as a block or
    /// double-quoted scalar; here those are double-quoted with escapes. Both
    /// are valid YAML and both round-trip, and chapter titles cannot contain
    /// either — `EpubParser.cleanText` collapses whitespace before a title
    /// ever reaches a note file.
    static func scalar(_ value: String) -> String {
        if value.contains(where: \.isYAMLControl) {
            return "\"\(value.map(\.yamlEscaped).joined())\""
        }
        guard needsQuoting(value) else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Whether a plain scalar would be read back as something other than
    /// this exact string. Mirrors libyaml's scalar analysis plus
    /// `serde_yaml`'s check that the plain form does not re-parse as a
    /// number, bool, or null.
    private static func needsQuoting(_ value: String) -> Bool {
        guard let first = value.first, let last = value.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        // Indicators that cannot open a plain scalar.
        if ",[]{}#&*!|>'\"%@`".contains(first) { return true }
        // `-`, `?`, and `:` can open one, but only with a non-space after
        // them — otherwise the line reads as a sequence entry or a mapping.
        if "-?:".contains(first) {
            let second = value.dropFirst().first
            if second == nil || second!.isWhitespace { return true }
        }
        if value.contains(": ") || value.contains(" #") { return true }
        if last == ":" { return true }
        return readsAsNull(value) || readsAsBool(value) || readsAsNumber(value)
    }

    /// YAML 1.2 core-schema resolution: would a bare `value` come back as
    /// null, a bool, or a number rather than as itself? Note that `yes`,
    /// `no`, `on`, and `off` are plain strings under the core schema — only
    /// YAML 1.1 read them as bools.
    private static func readsAsNull(_ value: String) -> Bool {
        ["null", "Null", "NULL", "~"].contains(value)
    }

    private static func readsAsBool(_ value: String) -> Bool {
        ["true", "True", "TRUE", "false", "False", "FALSE"].contains(value)
    }

    /// The core schema's int and float forms:
    /// `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`, plus hex and
    /// octal ints and the infinity/NaN spellings. `1_000` and `e5` are not
    /// numbers to YAML, so they stay plain.
    private static func readsAsNumber(_ value: String) -> Bool {
        var digits = Substring(value)
        if let sign = digits.first, sign == "+" || sign == "-" { digits = digits.dropFirst() }
        if digits.isEmpty { return false }
        if digits.hasPrefix("0x") || digits.hasPrefix("0o") { return true }
        if [".inf", ".Inf", ".INF", ".nan", ".NaN", ".NAN"].contains(String(digits)) { return true }

        var index = digits.startIndex
        var sawDigit = false
        func consumeDigits() {
            while index < digits.endIndex, digits[index].isASCIIDigit {
                sawDigit = true
                index = digits.index(after: index)
            }
        }

        consumeDigits()
        if index < digits.endIndex, digits[index] == "." {
            index = digits.index(after: index)
            consumeDigits()
        }
        guard sawDigit else { return false }

        if index < digits.endIndex, digits[index] == "e" || digits[index] == "E" {
            index = digits.index(after: index)
            if index < digits.endIndex, digits[index] == "+" || digits[index] == "-" {
                index = digits.index(after: index)
            }
            sawDigit = false
            consumeDigits()
            guard sawDigit else { return false }
        }
        return index == digits.endIndex
    }

    // MARK: Parsing

    /// Parses a frontmatter block into a `NoteFrontmatter`. Unknown keys are
    /// ignored, as serde's default is; a missing required key is an error,
    /// which is what makes a truncated file fail loudly rather than silently
    /// losing a note's identity.
    static func decode(_ yaml: String) throws -> NoteFrontmatter {
        var fields: [String: String] = [:]
        var lines = yaml.lines[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmed.isEmpty || line.trimmed.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: ":") else {
                throw CoreError.notes("yaml error: not a key/value line: \(line)")
            }
            let key = String(line[..<separator].trimmed)
            let rest = line[line.index(after: separator)...].trimmed

            if rest == "|" || rest == "|-" || rest == ">" || rest == ">-" {
                // A block scalar: the indented run that follows.
                var block: [Substring] = []
                while let next = lines.first, next.trimmed.isEmpty || next.hasPrefix(" ") {
                    lines = lines.dropFirst()
                    block.append(next.trimmedStart)
                }
                let joined = block.joined(separator: rest.hasPrefix("|") ? "\n" : " ")
                fields[key] = rest.hasSuffix("-") ? String(joined.trimmedEnd) : joined
            } else {
                fields[key] = unquote(rest)
            }
        }

        func required(_ key: String) throws -> String {
            guard let value = fields[key] else {
                throw CoreError.notes("yaml error: missing field `\(key)`")
            }
            return value
        }
        func requiredInt(_ key: String) throws -> Int {
            guard let value = Int(try required(key)) else {
                throw CoreError.notes("yaml error: field `\(key)` is not an integer")
            }
            return value
        }

        return NoteFrontmatter(
            bookId: try required("book_id"),
            chapterKey: try required("chapter_key"),
            chapterIndex: try requiredInt("chapter_index"),
            chapterTitle: try required("chapter_title"),
            chapterHref: try required("chapter_href"),
            epubCfi: fields["epub_cfi"].flatMap { $0 == "null" || $0 == "~" ? nil : $0 },
            kind: try required("kind"),
            wordCount: try requiredInt("word_count"),
            createdAt: fields["created_at"].flatMap(RFC3339.date(from:)),
            updatedAt: fields["updated_at"].flatMap(RFC3339.date(from:))
        )
    }

    /// Strips YAML quoting from a scalar, undoing `''` and backslash escapes.
    private static func unquote(_ raw: Substring) -> String {
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            return raw.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return unescape(raw.dropFirst().dropLast())
        }
        // A plain scalar runs to a ` #` comment.
        if let comment = raw.range(of: " #") {
            return String(raw[..<comment.lowerBound].trimmedEnd)
        }
        return String(raw)
    }

    private static func unescape(_ raw: Substring) -> String {
        var result = ""
        let characters = Array(raw)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            let escape = characters[index + 1]
            index += 2
            switch escape {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "u" where index + 4 <= characters.count:
                let hex = String(characters[index..<(index + 4)])
                index += 4
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                }
            default: result.append(escape)
            }
        }
        return result
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }

    /// Characters YAML cannot carry in a plain or single-quoted scalar.
    var isYAMLControl: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        if self == "\n" || self == "\t" { return true }
        return scalar.value < 0x20 || scalar.value == 0x7f
    }

    var yamlEscaped: String {
        switch self {
        case "\n": return "\\n"
        case "\t": return "\\t"
        case "\r": return "\\r"
        case "\\": return "\\\\"
        case "\"": return "\\\""
        default:
            guard isYAMLControl, let scalar = unicodeScalars.first else { return String(self) }
            return String(format: "\\u%04x", scalar.value)
        }
    }
}
