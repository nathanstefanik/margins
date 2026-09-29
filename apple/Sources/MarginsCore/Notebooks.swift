import Foundation

// Notebook files: the commonplace documents under `{root}/notebooks/`
// (docs/commonplace.md "Notebook storage"). One markdown file per
// notebook — YAML frontmatter (id, title, created_at, updated_at) over a
// body of prose paragraphs and `<!-- margins:passage … -->` blocks —
// plus a derived `_index.json` catalog.
//
// The round-trip contract is the same one `Marks` keeps: every segment
// remembers its exact source bytes (`raw` for passages, the text itself
// for prose), so concatenating the segments reproduces the body byte for
// byte, and a save rewrites only the blocks that actually changed.

public enum Notebooks {
    // MARK: Paths and the index

    /// `{root}/notebooks` — created on first write.
    static func dir(root: String) -> String {
        root.appendingPathComponent("notebooks")
    }

    private static func indexPath(dir: String) -> String {
        dir.appendingPathComponent("_index.json")
    }

    static func readIndex(dir: String) throws -> NotebooksIndex {
        let path = indexPath(dir: dir)
        guard FileStore.exists(path) else { return NotebooksIndex(notebooks: []) }
        do {
            return try MarginsJSON.decode(NotebooksIndex.self, from: FileStore.readData(path))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.notes("json error: \(error.localizedDescription)")
        }
    }

    /// `notebooks/_index.json`: the notebook list the catalog shows.
    /// Derived from the `.md` files — `listSummaries` rebuilds it whenever
    /// the two disagree (a file added or removed outside the app). Evicted
    /// iCloud placeholders keep their synced index entries and are never
    /// reparsed, and an evicted index is best-effort only: no rebuild
    /// writes over its placeholder.
    static func listSummaries(dir: String) throws -> [NotebookSummary] {
        let indexPath = indexPath(dir: dir)
        // `FileStore.exists` counts the placeholder, so an evicted index
        // enters readData and throws notDownloaded — record that case.
        let index = (try? readIndex(dir: dir)) ?? NotebooksIndex(notebooks: [])
        let indexEvicted = FileStore.isEvicted(indexPath)

        // `FileStore.contents` reports placeholders under their logical
        // names, so an evicted notebook still counts as a file here.
        let files =
            (Files.isDirectory(dir)
                ? (try? FileStore.contents(ofDirectory: dir)) ?? [] : [])
            .filter { $0.hasSuffix(".md") && FileStore.isFile($0) }
            .map { ($0 as NSString).lastPathComponent }

        var summaries = index.notebooks
        if Set(summaries.map(\.file)) != Set(files) {
            summaries = try rebuildIndex(
                dir: dir, files: files, index: index, writeIndex: !indexEvicted
            )
        }

        // `isEvicted` is a live property, not stored: recompute per file.
        return summaries
            .map { summary -> NotebookSummary in
                var summary = summary
                summary.isEvicted = FileStore.isEvicted(
                    dir.appendingPathComponent(summary.file))
                return summary
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                switch $0.title.localizedStandardCompare($1.title) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return $0.id < $1.id
                }
            }
    }

    /// Re-derives `_index.json` from the `.md` files on disk; files that
    /// fail to parse are left out. An evicted file keeps its previous
    /// index entry when one exists (the content lives on the machine that
    /// has it) and is otherwise omitted; `writeIndex` is false when the
    /// index itself is evicted.
    private static func rebuildIndex(
        dir: String, files: [String], index: NotebooksIndex, writeIndex: Bool
    ) throws -> [NotebookSummary] {
        var summaries: [NotebookSummary] = []
        for file in files {
            let path = dir.appendingPathComponent(file)
            if FileStore.isEvicted(path) {
                if let entry = index.notebooks.first(where: { $0.file == file }) {
                    summaries.append(entry)
                }
                continue
            }
            guard let parsed = try? parseFile(path: path)
            else { continue }
            summaries.append(summary(for: parsed, file: file))
        }
        if writeIndex {
            try FileStore.writeData(
                MarginsJSON.encode(NotebooksIndex(notebooks: summaries)),
                to: indexPath(dir: dir)
            )
        }
        return summaries
    }

    private static func upsertIndex(dir: String, summary: NotebookSummary) throws {
        var index = (try? readIndex(dir: dir)) ?? NotebooksIndex(notebooks: [])
        index.notebooks.removeAll { $0.id == summary.id }
        index.notebooks.append(summary)
        try FileStore.writeData(
            MarginsJSON.encode(index), to: indexPath(dir: dir)
        )
    }

    /// The index entry + path for `id`, after the same index reconciliation
    /// a listing does — so an externally added file is found by id too.
    private static func locate(dir: String, id: String) throws -> (entry: NotebookSummary, path: String) {
        guard let entry = try listSummaries(dir: dir).first(where: { $0.id == id }) else {
            throw CoreError.notes("notebook not found: \(id)")
        }
        return (entry, dir.appendingPathComponent(entry.file))
    }

    // MARK: CRUD

    static func create(dir: String, title: String) throws -> NotebookSummary {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CoreError.notes("notebook title is empty") }
        try Files.createDirectory(dir)
        let now = RFC3339.now()
        let file = uniqueFileName(dir: dir, title: title)
        let frontmatter = NotebookFrontmatter(
            id: CoreID.newID(), title: title, createdAt: now, updatedAt: now, unknown: []
        )
        try FileStore.write(render(frontmatter: frontmatter, body: ""), to: dir.appendingPathComponent(file))
        let summary = NotebookSummary(
            id: frontmatter.id, title: title, file: file,
            passageCount: 0, wordCount: 0, createdAt: now, updatedAt: now
        )
        try upsertIndex(dir: dir, summary: summary)
        return summary
    }

    /// Renames the notebook; the file follows the new title's slug (the id
    /// — hence the identity — never changes).
    static func rename(dir: String, id: String, title: String) throws -> NotebookSummary {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CoreError.notes("notebook title is empty") }
        let (entry, path) = try locate(dir: dir, id: id)
        var parsed = try parseFile(path: path)

        let file = uniqueFileName(dir: dir, title: title, excluding: entry.file)
        if file != entry.file {
            if FileStore.isEvicted(path) { throw CoreError.notDownloaded(path) }
            if FileStore.exists(path) {
                try FileStore.rename(path, to: dir.appendingPathComponent(file))
            }
        }
        parsed.frontmatter.title = title
        parsed.frontmatter.updatedAt = RFC3339.now()
        let destination = dir.appendingPathComponent(file)
        try FileStore.write(render(frontmatter: parsed.frontmatter, body: parsed.body), to: destination)

        let summary = NotebookSummary(
            id: entry.id, title: title, file: file,
            passageCount: entry.passageCount, wordCount: entry.wordCount,
            createdAt: entry.createdAt, updatedAt: parsed.frontmatter.updatedAt
        )
        try upsertIndex(dir: dir, summary: summary)
        return summary
    }

    /// Removes the file and its index entry. Returns the removed path.
    @discardableResult
    static func delete(dir: String, id: String) throws -> String {
        let (entry, path) = try locate(dir: dir, id: id)
        try FileStore.remove(path)
        var index = (try? readIndex(dir: dir)) ?? NotebooksIndex(notebooks: [])
        index.notebooks.removeAll { $0.id == entry.id }
        try FileStore.writeData(
            MarginsJSON.encode(index), to: indexPath(dir: dir)
        )
        return path
    }

    /// Loads one notebook with every passage resolved against the library.
    static func load(dir: String, id: String, root: String) throws -> Notebook {
        let (entry, path) = try locate(dir: dir, id: id)
        guard !FileStore.isEvicted(path) else { throw CoreError.notDownloaded(path) }
        let parsed = try parseFile(path: path)
        let segments = resolveSegments(parsed.segments, root: root)
        return Notebook(
            summary: summary(for: ParsedFile(
                frontmatter: parsed.frontmatter, body: parsed.body, segments: segments
            ), file: entry.file),
            segments: segments
        )
    }

    /// Saves the segment list the UI hands back. Prose emits verbatim;
    /// passages re-resolve in the core — an untouched block keeps its bytes
    /// while a block whose live quote or citation changed is regenerated.
    /// `updated_at` bumps on every save.
    static func save(dir: String, id: String, segments: [NotebookSegment], root: String) throws -> Notebook {
        let (entry, path) = try locate(dir: dir, id: id)
        guard !FileStore.isEvicted(path) else { throw CoreError.notDownloaded(path) }
        var parsed = try parseFile(path: path)

        let rendered = renderBody(segments, root: root)
        parsed.frontmatter.updatedAt = RFC3339.now()
        try FileStore.write(
            render(frontmatter: parsed.frontmatter, body: rendered.body), to: path
        )

        let summary = summary(
            for: ParsedFile(
                frontmatter: parsed.frontmatter, body: rendered.body, segments: rendered.segments
            ),
            file: entry.file
        )
        try upsertIndex(dir: dir, summary: summary)
        return Notebook(summary: summary, segments: rendered.segments)
    }

    /// Appends a passage at the end of the notebook, plus the commentary
    /// as a prose paragraph when it is non-empty after trimming.
    static func appendPassage(
        dir: String, id: String, ref: PassageRef, commentary: String, root: String
    ) throws -> Notebook {
        let notebook = try load(dir: dir, id: id, root: root)
        var segments = notebook.segments
        segments.append(
            NotebookSegment(
                id: "s\(segments.count)",
                content: .passage(
                    NotebookPassage(
                        ref: ref, cachedQuote: "", raw: nil,
                        resolution: PassageResolution(status: .ok, quote: "")
                    )
                )
            )
        )
        let commentary = commentary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commentary.isEmpty {
            segments.append(
                NotebookSegment(id: "s\(segments.count)", content: .prose("\n\(commentary)\n"))
            )
        }
        return try save(dir: dir, id: id, segments: segments, root: root)
    }

    // MARK: File format

    /// The frontmatter of a notebook file. `unknown` keeps every line whose
    /// key is not one of ours — comments and blank lines included — so a
    /// re-save preserves them verbatim in order.
    struct NotebookFrontmatter {
        var id: String
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var unknown: [String]
    }

    /// A notebook file's parts, pre-resolution.
    struct ParsedFile {
        var frontmatter: NotebookFrontmatter
        /// The post-frontmatter bytes, verbatim.
        var body: String
        var segments: [NotebookSegment]
    }

    static func parseFile(path: String) throws -> ParsedFile {
        try parseContent(try FileStore.read(path))
    }

    static func parseContent(_ raw: String) throws -> ParsedFile {
        let (yaml, body) = try splitFrontmatter(raw)
        let frontmatter = try parseFrontmatter(yaml)
        return ParsedFile(frontmatter: frontmatter, body: body, segments: parseBody(body))
    }

    /// `passage_count` counts passage segments; `word_count` counts prose
    /// words only (passage blocks are quoted text, not the reader's words).
    static func summary(for parsed: ParsedFile, file: String) -> NotebookSummary {
        var passages = 0
        var words = 0
        for segment in parsed.segments {
            switch segment.content {
            case .prose(let text): words += Notes.countWords(text)
            case .passage: passages += 1
            }
        }
        return NotebookSummary(
            id: parsed.frontmatter.id, title: parsed.frontmatter.title, file: file,
            passageCount: passages, wordCount: words,
            createdAt: parsed.frontmatter.createdAt, updatedAt: parsed.frontmatter.updatedAt
        )
    }

    /// Splits `---\n…\n---\n` off the front of a notebook file — the same
    /// fence shape chapter notes use.
    private static func splitFrontmatter(_ raw: String) throws -> (yaml: String, content: String) {
        guard raw.hasPrefix("---\n") else {
            throw CoreError.notes("notebook file missing YAML frontmatter")
        }
        let afterOpen = raw.index(raw.startIndex, offsetBy: 4)
        guard let close = raw.range(of: "\n---", range: afterOpen..<raw.endIndex) else {
            throw CoreError.notes("notebook file missing YAML frontmatter")
        }
        var contentStart = close.upperBound
        if contentStart < raw.endIndex, raw[contentStart] == "\n" {
            contentStart = raw.index(after: contentStart)
        }
        return (String(raw[afterOpen..<close.lowerBound]), String(raw[contentStart...]))
    }

    private static func parseFrontmatter(_ yaml: String) throws -> NotebookFrontmatter {
        var id: String?
        var title: String?
        var createdAt: Date?
        var updatedAt: Date?
        var unknown: [String] = []
        for field in Frontmatter.parseOrdered(yaml) {
            switch field.key {
            case "id": id = field.value
            case "title": title = field.value
            case "created_at": createdAt = RFC3339.date(from: field.value)
            case "updated_at": updatedAt = RFC3339.date(from: field.value)
            default: unknown.append(field.raw)
            }
        }
        guard let id, !id.isEmpty, let title else {
            throw CoreError.notes("notebook file missing id or title")
        }
        return NotebookFrontmatter(
            id: id, title: title,
            createdAt: createdAt ?? RFC3339.now(), updatedAt: updatedAt ?? RFC3339.now(),
            unknown: unknown
        )
    }

    /// The file body, split into ordered segments. Every byte lands in
    /// exactly one segment — prose keeps its text (blank lines included),
    /// a passage keeps the comment line through its last `>` line as `raw`
    /// — so concatenating raw segments reproduces the body byte for byte.
    static func parseBody(_ body: String) -> [NotebookSegment] {
        // Lines with their terminator, so segments carry exact bytes.
        var lines: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            if let newline = body[index...].firstIndex(of: "\n") {
                lines.append(String(body[index...newline]))
                index = body.index(after: newline)
            } else {
                lines.append(String(body[index...]))
                index = body.endIndex
            }
        }

        var segments: [NotebookSegment] = []
        var prose = ""
        var counter = 0
        func flushProse() {
            guard !prose.isEmpty else { return }
            segments.append(NotebookSegment(id: "s\(counter)", content: .prose(prose)))
            prose = ""
            counter += 1
        }

        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine
            guard let ref = parsePassageComment(line) else {
                prose += rawLine
                i += 1
                continue
            }

            flushProse()
            var raw = rawLine
            var quoteLines: [String] = []
            i += 1
            while i < lines.count {
                let next = lines[i]
                let content = next.hasSuffix("\n") ? String(next.dropLast()) : next
                guard content.trimmedStart.hasPrefix(">") else { break }
                raw += next
                quoteLines.append(content)
                i += 1
            }

            // The last `>` line is the citation when it starts `> — ` — it
            // is regenerated on write, so it is not part of the quote.
            if let last = quoteLines.last, last.trimmedStart.hasPrefix("> — ") {
                quoteLines.removeLast()
            }
            let cachedQuote = quoteLines.map { line -> String in
                let quoted = line.trimmedStart.strippingPrefix(">") ?? ""
                return String(quoted.strippingPrefix(" ") ?? quoted)
            }.joined(separator: "\n")

            segments.append(
                NotebookSegment(
                    id: "s\(counter)",
                    content: .passage(
                        NotebookPassage(
                            ref: ref, cachedQuote: cachedQuote, raw: raw,
                            resolution: PassageResolution(status: .ok, quote: cachedQuote)
                        )
                    )
                )
            )
            counter += 1
        }
        flushProse()
        return segments
    }

    /// `<!-- margins:passage book=… chapter=… mark=… -->` → the ref, or
    /// `nil` — a comment that fails to parse is prose, never dropped.
    private static func parsePassageComment(_ line: String) -> PassageRef? {
        let trimmed = line.trimmed
        guard let inner = trimmed.strippingPrefix("<!--")?.strippingSuffix("-->")?.trimmed,
            let attributes = inner.strippingPrefix("margins:passage"),
            let first = attributes.first, first.isWhitespace
        else { return nil }
        var bookId: String?
        var chapterKey: String?
        var markId: String?
        for (key, value) in parseAttributes(attributes) {
            switch key {
            case "book": bookId = value
            case "chapter": chapterKey = value
            case "mark": markId = value
            default: break
            }
        }
        guard let bookId, !bookId.isEmpty, let chapterKey, !chapterKey.isEmpty,
            let markId, !markId.isEmpty
        else { return nil }
        return PassageRef(bookId: bookId, chapterKey: chapterKey, markId: markId)
    }

    /// Whitespace-separated `key=value` tokens; values may be double-quoted
    /// — the same attribute shape mark comments use.
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
                attributes[index] != "=", !attributes[index].isWhitespace
            {
                key.append(attributes[index])
                index = attributes.index(after: index)
            }
            guard index < attributes.endIndex, attributes[index] == "=" else {
                while index < attributes.endIndex, !attributes[index].isWhitespace {
                    index = attributes.index(after: index)
                }
                continue
            }
            index = attributes.index(after: index)

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

    /// Re-parses a passage block's raw bytes: the ref and cached quote the
    /// block carries, plus the raw citation line when present. Used on
    /// save to decide whether the block stays byte-identical.
    private static func parsePassageBlock(
        _ raw: String
    ) -> (ref: PassageRef?, quote: String, citation: String?) {
        let lines = raw.lines
        let ref = lines.first.map { parsePassageComment(String($0)) } ?? nil
        var quoteLines = lines.dropFirst().map(String.init)
        var citation: String?
        if let last = quoteLines.last, last.trimmedStart.hasPrefix("> — ") {
            citation = last
            quoteLines.removeLast()
        }
        let quote = quoteLines.map { line -> String in
            let quoted = line.trimmedStart.strippingPrefix(">") ?? ""
            return String(quoted.strippingPrefix(" ") ?? quoted)
        }.joined(separator: "\n")
        return (ref, quote, citation)
    }

    /// Should the loaded block keep its exact bytes? Yes when the ref is
    /// unchanged and either the passage is unresolved (a save must never
    /// rewrite what it could not read) or the live quote and regenerated
    /// citation both match what the block already carries.
    private static func keepsRaw(raw: String, passage: NotebookPassage) -> Bool {
        let parsed = parsePassageBlock(raw)
        guard parsed.ref == passage.ref else { return false }
        let resolution = passage.resolution
        guard resolution.status == .ok else { return true }
        return parsed.quote == resolution.quote
            && citationText(resolution) == parsed.citation
    }

    /// The canonical passage block: comment line, quote lines (`> `, a
    /// bare `>` for an empty one), then the `> — author, *title*, chapter`
    /// citation (omitted parts drop out, commas with them).
    private static func canonicalBlock(ref: PassageRef, resolution: PassageResolution) -> String {
        var block =
            "<!-- margins:passage book=\(ref.bookId) chapter=\(ref.chapterKey)"
            + " mark=\(ref.markId) -->\n"
        for line in resolution.quote.lines {
            block += line.isEmpty ? ">\n" : "> \(line)\n"
        }
        if let citation = citationText(resolution) {
            block += citation + "\n"
        }
        return block
    }

    /// `> — Author, *Title*, Chapter` — the title is markdown-escaped
    /// inside the emphasis; `nil` when there is nothing to cite.
    private static func citationText(_ resolution: PassageResolution) -> String? {
        var parts: [String] = []
        if let author = resolution.bookAuthor, !author.isEmpty { parts.append(author) }
        if let title = resolution.bookTitle, !title.isEmpty {
            parts.append("*\(Compile.escapeMarkdown(title))*")
        }
        if let chapter = resolution.chapterTitle, !chapter.isEmpty { parts.append(chapter) }
        guard !parts.isEmpty else { return nil }
        return "> — " + parts.joined(separator: ", ")
    }

    /// Renders segments to body bytes. Verbatim parts emit as-is; a new or
    /// regenerated passage block is padded to start on a blank line (or at
    /// the empty start) and followed by one blank line — neighbours' bytes
    /// are never modified.
    private static func renderBody(
        _ segments: [NotebookSegment], root: String
    ) -> (body: String, segments: [NotebookSegment]) {
        var cache: [String: ResolvedSource] = [:]
        var parts: [(text: String, canonical: Bool)] = []
        var resolved: [NotebookSegment] = []

        for segment in segments {
            switch segment.content {
            case .prose(let text):
                parts.append((text, false))
                resolved.append(
                    NotebookSegment(id: "s\(resolved.count)", content: .prose(text)))
            case .passage(let passage):
                var passage = passage
                passage.resolution = resolve(
                    ref: passage.ref, cachedQuote: passage.cachedQuote, root: root,
                    cache: &cache
                )
                var emitted = passage.raw ?? ""
                var canonical = true
                if !emitted.isEmpty, keepsRaw(raw: emitted, passage: passage) {
                    passage.cachedQuote = parsePassageBlock(emitted).quote
                    canonical = false
                } else {
                    emitted = canonicalBlock(ref: passage.ref, resolution: passage.resolution)
                    passage.cachedQuote = passage.resolution.quote
                    passage.raw = emitted
                }
                parts.append((emitted, canonical))
                resolved.append(
                    NotebookSegment(id: "s\(resolved.count)", content: .passage(passage)))
            }
        }

        var body = ""
        for (position, part) in parts.enumerated() {
            guard part.canonical else {
                body += part.text
                continue
            }
            if !body.isEmpty && !body.hasSuffix("\n\n") {
                body += body.hasSuffix("\n") ? "\n" : "\n\n"
            }
            body += part.text
            if position + 1 < parts.count, !parts[position + 1].text.hasPrefix("\n"),
                !parts[position + 1].text.isEmpty
            {
                body += "\n"
            }
        }
        return (body, resolved)
    }

    // MARK: Resolution

    /// What a passage ref resolves to, cached per (book, chapter) for the
    /// duration of one resolve pass.
    private enum ResolvedSource {
        case ok(meta: BookMeta, note: ChapterNote?)
        case bookMissing
        case notDownloaded
    }

    /// Resolves the passage's mark in the live library (docs/commonplace.md
    /// "Resolution"). The quote is the live mark quote — or its body when
    /// the quote is empty — and the cached quote when unresolved.
    private static func resolve(
        ref: PassageRef, cachedQuote: String, root: String,
        cache: inout [String: ResolvedSource]
    ) -> PassageResolution {
        let key = "\(ref.bookId)/\(ref.chapterKey)"
        if cache[key] == nil { cache[key] = loadSource(ref: ref, root: root) }
        switch cache[key]! {
        case .bookMissing:
            return PassageResolution(status: .bookMissing, quote: cachedQuote)
        case .notDownloaded:
            return PassageResolution(status: .notDownloaded, quote: cachedQuote)
        case .ok(let meta, let note):
            let chapterTitle =
                meta.chapters.first(where: { $0.key == ref.chapterKey })?.title
                ?? note?.frontmatter.chapterTitle
            guard let mark = note?.marks.first(where: { $0.id == ref.markId }) else {
                return PassageResolution(
                    status: .markMissing, quote: cachedQuote,
                    bookTitle: meta.title, bookAuthor: meta.author,
                    chapterTitle: chapterTitle
                )
            }
            return PassageResolution(
                status: .ok, quote: mark.quote.isEmpty ? mark.body : mark.quote,
                bookTitle: meta.title, bookAuthor: meta.author,
                chapterTitle: chapterTitle,
                cfi: mark.cfi, percent: mark.percent, markBody: mark.body
            )
        }
    }

    private static func resolveSegments(_ segments: [NotebookSegment], root: String) -> [NotebookSegment] {
        var cache: [String: ResolvedSource] = [:]
        return segments.map { segment in
            guard case .passage(let passage) = segment.content else { return segment }
            var resolved = passage
            resolved.resolution = resolve(
                ref: passage.ref, cachedQuote: passage.cachedQuote, root: root, cache: &cache
            )
            return NotebookSegment(id: segment.id, content: .passage(resolved))
        }
    }

    /// Loads the book meta and chapter note a ref points at. `meta.json`
    /// missing or corrupt → `bookMissing`; an evicted read →
    /// `notDownloaded`; a note that cannot be read parses as none, which
    /// surfaces as `markMissing` downstream.
    private static func loadSource(ref: PassageRef, root: String) -> ResolvedSource {
        let bookDir = root.appendingPathComponent("books").appendingPathComponent(ref.bookId)
        let metaPath = bookDir.appendingPathComponent("meta.json")
        guard FileStore.exists(metaPath) else { return .bookMissing }
        let meta: BookMeta
        do {
            meta = try MarginsJSON.decode(BookMeta.self, from: FileStore.readData(metaPath))
        } catch let error as CoreError {
            if case .notDownloaded = error { return .notDownloaded }
            return .bookMissing
        } catch {
            return .bookMissing
        }

        var note: ChapterNote?
        do {
            if let entry = try Notes.readIndex(bookDir: bookDir).chapters
                .first(where: { $0.chapterKey == ref.chapterKey })
            {
                let path = bookDir.appendingPathComponent("notes").appendingPathComponent(entry.file)
                if FileStore.isEvicted(path) { return .notDownloaded }
                if FileStore.exists(path) {
                    note = try? Notes.parseNoteFile(path: path, chapterKey: ref.chapterKey)
                }
            }
        } catch let error as CoreError {
            if case .notDownloaded = error { return .notDownloaded }
        } catch {
            // A corrupt index leaves the mark unfindable: markMissing.
        }
        return .ok(meta: meta, note: note)
    }

    // MARK: Rendering helpers

    private static func render(frontmatter: NotebookFrontmatter, body: String) -> String {
        var lines = [
            "id: \(frontmatter.id)",
            "title: '\(frontmatter.title.replacingOccurrences(of: "'", with: "''"))'",
            "created_at: \(RFC3339.string(from: frontmatter.createdAt))",
            "updated_at: \(RFC3339.string(from: frontmatter.updatedAt))",
        ]
        lines.append(contentsOf: frontmatter.unknown)
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    /// `{slug}.md`, `notebook` when the slug is empty, `-2`/`-3`/… on
    /// collision. `excluding` keeps the notebook's own file available
    /// through a rename.
    private static func uniqueFileName(dir: String, title: String, excluding: String? = nil) -> String {
        var base = Notes.slugify(title)
        if base.isEmpty { base = "notebook" }
        var file = "\(base).md"
        var counter = 2
        while file != excluding, FileStore.exists(dir.appendingPathComponent(file)) {
            file = "\(base)-\(counter).md"
            counter += 1
        }
        return file
    }
}

/// `notebooks/_index.json` — derived catalog entries, rebuilt whenever
/// the `.md` files disagree with it.
struct NotebooksIndex: Codable {
    var notebooks: [NotebookSummary]
}
