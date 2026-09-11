import Foundation

// Compiles a book's per-chapter notes into one ordered document and renders
// it as markdown. A read/compose layer over the existing note files — no
// storage change.

public enum Compile {
    /// Reads `meta.json` + `notes/_index.json`, loads each listed note, and
    /// returns them in spine order. Chapters with no note file are omitted
    /// from `chapters` but counted in `chapterCount`; a missing or
    /// unparsable individual note is skipped rather than sinking the whole
    /// compilation (the same forgiving posture as `Notes.readIndex`).
    public static func bookNotes(bookDir: String) throws -> CompiledNotes {
        let meta = try Notes.readMeta(bookDir: bookDir)
        let index = try Notes.readIndex(bookDir: bookDir)
        let notesDir = bookDir.appendingPathComponent("notes")

        // Note frontmatter records the chapter title as it stood when the
        // note was saved, so a book whose titles were re-derived (see
        // `Library.chaptersVersion`) would show stale names here. The spine
        // is the source of truth; frontmatter only fills in for keys it no
        // longer has. Note files are left untouched on disk.
        let spineTitles = Dictionary(
            meta.chapters.map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first }
        )

        var chapters: [CompiledChapter] = []
        var firstCreatedAt: Date?
        var lastUpdatedAt: Date?

        for entry in index.chapters {
            guard let note = try? Notes.parseNoteFile(
                path: notesDir.appendingPathComponent(entry.file), chapterKey: entry.chapterKey
            ) else { continue }

            firstCreatedAt = earlier(firstCreatedAt, note.frontmatter.createdAt)
            lastUpdatedAt = later(lastUpdatedAt, note.frontmatter.updatedAt)
            chapters.append(
                CompiledChapter(
                    chapterKey: entry.chapterKey,
                    chapterIndex: note.frontmatter.chapterIndex,
                    chapterTitle: spineTitles[entry.chapterKey] ?? note.frontmatter.chapterTitle,
                    body: note.body,
                    marks: Marks.sortedByReadingOrder(note.marks),
                    // Recounted from the body so the page always agrees with
                    // what it displays, even for hand-edited note files.
                    wordCount: Notes.countWords(note.body),
                    updatedAt: note.frontmatter.updatedAt
                )
            )
        }
        // Defensive re-sort; `_index.json` is already sorted on save.
        chapters = stableSortedByIndex(chapters)

        let withNotes = Set(chapters.map(\.chapterKey))
        let emptyChapters = stableSortedByIndex(
            meta.chapters
                .filter { !withNotes.contains($0.key) }
                .map {
                    CompiledChapter(
                        chapterKey: $0.key, chapterIndex: $0.index, chapterTitle: $0.title,
                        body: "", wordCount: 0
                    )
                }
        )

        var compiled = CompiledNotes(
            bookId: meta.id,
            bookTitle: meta.title,
            bookAuthor: meta.author,
            chapters: chapters,
            emptyChapters: emptyChapters,
            chaptersWithNotes: chapters.count,
            chapterCount: meta.chapters.count,
            totalWords: chapters.reduce(0) { $0 + $1.wordCount },
            firstCreatedAt: firstCreatedAt,
            lastUpdatedAt: lastUpdatedAt,
            suggestedFilename: ""
        )
        compiled.suggestedFilename = suggestedExportFilename(compiled)
        return compiled
    }

    /// Renders the compiled notes as deterministic markdown. An empty book
    /// renders a "no notes" document, not an error.
    public static func renderMarkdown(
        _ notes: CompiledNotes, options: ExportOptions = .default
    ) -> String {
        var out = "# Notes — \(escapeMarkdown(notes.bookTitle))\n\n"
        out += "*\(escapeMarkdown(notes.bookAuthor))*"

        if options.includeStats {
            var parts = [
                "\(notes.chaptersWithNotes)/\(notes.chapterCount) chapters annotated",
                "\(notes.totalWords) words",
            ]
            if let updated = notes.lastUpdatedAt {
                parts.append("last updated \(formatDate(updated))")
            }
            out += " · \(parts.joined(separator: " · "))"
        }
        out += "\n\n"

        // Sections in spine order; note-less chapters join only when gaps
        // are wanted (as `_No note._` stubs).
        var sections = notes.chapters.map { (chapter: $0, isStub: false) }
        if options.includeEmptyChapters {
            sections += notes.emptyChapters.map { (chapter: $0, isStub: true) }
        }
        sections = sections.enumerated()
            .sorted { ($0.element.chapter.chapterIndex, $0.offset)
                < ($1.element.chapter.chapterIndex, $1.offset) }
            .map(\.element)

        guard !sections.isEmpty else { return out + "_No notes yet._\n" }

        if options.includeToc {
            out += "## Contents\n\n"
            var seen: [String: Int] = [:]
            for section in sections {
                let anchor = tocAnchor(
                    section.chapter.chapterIndex, section.chapter.chapterTitle, seen: &seen
                )
                out += "- [\(section.chapter.chapterIndex + 1). "
                    + "\(escapeMarkdown(section.chapter.chapterTitle))](#\(anchor))\n"
            }
            out += "\n"
        }

        for section in sections {
            let chapter = section.chapter
            out += "---\n\n"
            out += "## \(chapter.chapterIndex + 1). \(escapeMarkdown(chapter.chapterTitle))\n"

            if section.isStub {
                out += "\n_No note._\n\n"
                continue
            }
            if chapter.wordCount > 0 || chapter.updatedAt != nil {
                var parts = ["\(chapter.wordCount) words"]
                if let updated = chapter.updatedAt {
                    parts.append("updated \(formatDate(updated))")
                }
                out += "\n*\(parts.joined(separator: " · "))*\n"
            }

            var body = String(chapter.body.trimmed)
            if !body.isEmpty {
                if options.demoteHeadings { body = demoteHeadings(body) }
                body = String(body.trimmed)
                if !body.isEmpty {
                    out += "\n\(body)\n"
                }
            }
            out += renderMarks(chapter.marks)
            // Always close the section with a blank line so a trailing
            // paragraph never merges with the next `---` (setext heading).
            out += "\n"
        }
        return out
    }

    /// Shared default export name: `"{author} — {title} — notes.md"`, with
    /// path-hostile characters stripped so both frontends propose the same
    /// safe name.
    public static func suggestedExportFilename(_ notes: CompiledNotes) -> String {
        "\(sanitizeFilenameComponent(notes.bookAuthor)) — "
            + "\(sanitizeFilenameComponent(notes.bookTitle)) — notes.md"
    }

    // MARK: Rendering pieces

    /// Renders a chapter's marks (already in reading order) as plain
    /// markdown — blockquote for the selection, body paragraphs, and a quiet
    /// italic attribution line. No HTML comments ever reach the export.
    private static func renderMarks(_ marks: [Mark]) -> String {
        guard !marks.isEmpty else { return "" }
        var out = "\n### Marks\n"
        for mark in marks {
            out += "\n"
            for line in mark.quote.lines {
                out += "> \(line)\n"
            }
            if !mark.body.isEmpty {
                if !mark.quote.isEmpty { out += "\n" }
                out += "\(mark.body)\n"
            }
            var attribution = "*— "
            if let percent = mark.percent {
                attribution += String(format: "%.1f%% · ", percent)
            }
            attribution += "\(formatDate(mark.at))*\n"
            out += attribution
        }
        return out
    }

    /// Shared with the club export naming (`ClubCompile.suggestedExportFilename`).
    static func sanitizeFilenameComponent(_ text: String) -> String {
        let spaced = text.map { "/:\\<>\"|?*\0".contains($0) ? " " : String($0) }.joined()
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// GitHub-style TOC anchor for `"{n}. {title}"`, reusing the note-file
    /// slug. Collisions get `-2`, `-3`, … suffixes in encounter order.
    /// Internal so the test target can exercise the collision logic directly.
    static func tocAnchor(
        _ chapterIndex: Int, _ title: String, seen: inout [String: Int]
    ) -> String {
        let base = Notes.slugify("\(chapterIndex + 1). \(title)")
        seen[base, default: 0] += 1
        let count = seen[base] ?? 1
        return count == 1 ? base : "\(base)-\(count)"
    }

    /// Escapes markdown-significant characters in titles/authors
    /// interpolated into the document so a `#`-prefixed chapter title cannot
    /// forge headings.
    static func escapeMarkdown(_ text: String) -> String {
        text.map { "\\`*_[]#<>|".contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    /// Shifts ATX headings (`#`…`######`) down two levels so user headings
    /// never collide with the document's `#`/`##` structure; capped at `h6`.
    static func demoteHeadings(_ body: String) -> String {
        body.lines.map { line -> String in
            let hashes = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(hashes)
            let isHeading = (1...6).contains(hashes)
                && (rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t"))
            guard isHeading else { return String(line) }
            return String(repeating: "#", count: min(hashes + 2, 6)) + rest
        }.joined(separator: "\n")
    }

    /// Fixed-locale "Sep 1, 2026", matching chrono's `%b %-d, %Y`.
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    // MARK: Ordering

    /// Stable sort by chapter index, so chapters sharing an index keep the
    /// order the notes index gave them.
    private static func stableSortedByIndex(_ chapters: [CompiledChapter]) -> [CompiledChapter] {
        chapters.enumerated()
            .sorted { ($0.element.chapterIndex, $0.offset) < ($1.element.chapterIndex, $1.offset) }
            .map(\.element)
    }

    private static func earlier(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return min(a, b)
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }
}
