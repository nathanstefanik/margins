import Foundation

// Chapter note files: read, save, and the mark mutations that edit one block
// of a file without touching its neighbours. The file format — YAML
// frontmatter, long-form body, optional marks section — is docs/storage.md;
// `Frontmatter` owns the YAML and `Marks` owns the section below the
// sentinel, so what is left here is the file layout and the notes index.

public enum Notes {
    // MARK: The index

    public static func writeEmptyIndex(bookDir: String) throws {
        let notesDir = bookDir.appendingPathComponent("notes")
        try Files.createDirectory(notesDir.appendingPathComponent("chapters"))
        try FileStore.writeData(
            MarginsJSON.encode(NotesIndex(chapters: [])),
            to: notesDir.appendingPathComponent("_index.json")
        )
    }

    /// Reads the book's `notes/_index.json`. A missing index is "no notes";
    /// an unreadable or malformed one is an error, because silently
    /// reporting zero notes for a book that has them would let a later save
    /// overwrite the index outright.
    public static func readIndex(bookDir: String) throws -> NotesIndex {
        let path = bookDir.appendingPathComponent("notes/_index.json")
        guard FileStore.exists(path) else { return NotesIndex(chapters: []) }
        do {
            return try MarginsJSON.decode(NotesIndex.self, from: FileStore.readData(path))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.notes("json error: \(error.localizedDescription)")
        }
    }

    public static func countNotes(bookDir: String) throws -> Int {
        let chaptersDir = bookDir.appendingPathComponent("notes/chapters")
        guard Files.exists(chaptersDir) else { return 0 }
        return try FileStore.contents(ofDirectory: chaptersDir)
            .filter { $0.hasSuffix(".md") }
            .count
    }

    /// Deletes every note file under `notes/chapters/` and resets
    /// `notes/_index.json` to empty. Returns how many note files were
    /// removed. Everything else about the book (spine, reading position) is
    /// untouched.
    @discardableResult
    public static func clearBookNotes(bookDir: String) throws -> Int {
        let chaptersDir = bookDir.appendingPathComponent("notes/chapters")
        var removed = 0
        if Files.exists(chaptersDir) {
            for path in try FileStore.contents(ofDirectory: chaptersDir)
            where path.hasSuffix(".md") && FileStore.isFile(path) {
                try FileStore.remove(path)
                removed += 1
            }
        }
        try writeEmptyIndex(bookDir: bookDir)
        return removed
    }

    // MARK: Reading

    /// The chapter's note, or a blank one when the chapter has no file yet.
    public static func loadChapterNote(bookDir: String, chapterKey: String) throws -> ChapterNote {
        let notesDir = bookDir.appendingPathComponent("notes")
        let index = try readIndex(bookDir: bookDir)

        if let entry = index.chapters.first(where: { $0.chapterKey == chapterKey }) {
            return try parseNoteFile(
                path: notesDir.appendingPathComponent(entry.file), chapterKey: chapterKey
            )
        }

        let meta = try readMeta(bookDir: bookDir)
        guard let chapter = meta.chapters.first(where: { $0.key == chapterKey }) else {
            throw CoreError.notes("unknown chapter: \(chapterKey)")
        }
        return blankNote(bookId: meta.id, chapter: chapter)
    }

    static func parseNoteFile(path: String, chapterKey: String) throws -> ChapterNote {
        let note = try parseNoteContent(try FileStore.read(path), chapterKey: chapterKey)
        return ChapterNote(
            frontmatter: note.frontmatter,
            body: note.body,
            marks: Marks.marks(note.items),
            path: path
        )
    }

    // MARK: Saving

    /// Writes the chapter's note file and its index entry.
    ///
    /// Marks: the incoming body is authoritative for any marks section it
    /// carries (a blob frontend saving back what it loaded, possibly with
    /// hand edits); if it carries none, the marks already on disk are
    /// preserved verbatim. Either way a marks-unaware save cannot destroy
    /// them.
    @discardableResult
    public static func saveChapterNote(
        bookDir: String,
        chapter: ChapterMeta,
        frontmatter: NoteFrontmatter,
        body: String
    ) throws -> ChapterNote {
        var frontmatter = frontmatter
        let notesDir = bookDir.appendingPathComponent("notes")
        try Files.createDirectory(notesDir.appendingPathComponent("chapters"))

        let relativePath = "chapters/\(chapter.key)-\(slugify(chapter.title)).md"
        let path = notesDir.appendingPathComponent(relativePath)

        // The file name carries the chapter's title slug, so a chapter whose
        // title was re-derived since the note was written (see
        // `Library.chaptersVersion`) would otherwise leave the old file
        // behind, outside `_index.json` and invisible to every reader. Move
        // it to the new name instead: one file per chapter is the contract.
        if let previous = try readIndex(bookDir: bookDir).chapters
            .first(where: { $0.chapterKey == chapter.key })?.file {
            let source = notesDir.appendingPathComponent(previous)
            if previous != relativePath, FileStore.isFile(source), !FileStore.exists(path) {
                try? FileStore.rename(source, to: path)
            }
        }

        // Read from the final path — after the rename above, the index may
        // still point at the old name.
        let existing = FileStore.isFile(path)
            ? try? parseNoteContent(try FileStore.read(path), chapterKey: chapter.key)
            : nil

        let split = Marks.splitBody(body)
        let items: [MarkItem]
        if let section = split.section {
            items = Marks.parseSection(section)
        } else {
            items = existing?.items ?? []
        }

        let now = RFC3339.now()
        frontmatter.createdAt = existing?.frontmatter.createdAt ?? frontmatter.createdAt ?? now
        frontmatter.updatedAt = now
        frontmatter.wordCount = countWords(split.body)

        try FileStore.write(render(frontmatter: frontmatter, body: split.body, items: items), to: path)
        try upsertIndexEntry(
            bookDir: bookDir,
            chapter: chapter,
            file: relativePath,
            wordCount: frontmatter.wordCount,
            markCount: Marks.marks(items).count,
            updatedAt: frontmatter.updatedAt
        )

        return ChapterNote(
            frontmatter: frontmatter,
            body: split.body,
            marks: Marks.marks(items),
            path: path
        )
    }

    // MARK: Marks

    /// Appends a mark to the chapter's note file, creating the file (and its
    /// index entry) when the chapter has no note yet. The id and timestamp
    /// are assigned here; the returned `Mark` is what callers persist.
    @discardableResult
    public static func appendMark(
        bookDir: String,
        chapter: ChapterMeta,
        cfi: String?,
        percent: Double?,
        quote: String,
        body: String
    ) throws -> Mark {
        let existing = try readNoteFile(bookDir: bookDir, chapter: chapter)
        let now = RFC3339.now()

        var frontmatter = try existing?.frontmatter
            ?? blankNote(bookId: readMeta(bookDir: bookDir).id, chapter: chapter).frontmatter
        if existing == nil { frontmatter.createdAt = now }
        frontmatter.updatedAt = now

        var items = existing?.items ?? []
        let existingBody = existing?.body ?? ""
        let takenIDs = Set(Marks.marks(items).map(\.id))

        var id = Marks.newMarkID()
        while takenIDs.contains(id) { id = Marks.newMarkID() }
        let mark = Mark(id: id, cfi: cfi, at: now, percent: percent, quote: quote, body: body)
        Marks.append(mark, to: &items)

        try writeNoteFile(
            bookDir: bookDir, chapter: chapter,
            frontmatter: frontmatter, body: existingBody, items: items
        )
        try upsertIndexEntry(
            bookDir: bookDir,
            chapter: chapter,
            file: try noteRelativePath(bookDir: bookDir, chapter: chapter),
            wordCount: frontmatter.wordCount,
            markCount: Marks.marks(items).count,
            updatedAt: now
        )
        return mark
    }

    /// Replaces the mark with `mark.id`; other blocks keep their bytes.
    public static func updateMark(bookDir: String, chapter: ChapterMeta, mark: Mark) throws {
        guard let note = try readNoteFile(bookDir: bookDir, chapter: chapter) else {
            throw CoreError.notes("no note for chapter \(chapter.key)")
        }
        var items = note.items
        guard Marks.update(mark, in: &items) else {
            throw CoreError.notes("mark not found")
        }
        try rewriteKeepingBody(bookDir: bookDir, chapter: chapter, note: note, items: items)
    }

    /// Removes the mark with `id`; other blocks keep their bytes.
    public static func deleteMark(bookDir: String, chapter: ChapterMeta, id: String) throws {
        guard let note = try readNoteFile(bookDir: bookDir, chapter: chapter) else {
            throw CoreError.notes("no note for chapter \(chapter.key)")
        }
        var items = note.items
        guard Marks.delete(id: id, from: &items) else {
            throw CoreError.notes("mark not found")
        }
        try rewriteKeepingBody(bookDir: bookDir, chapter: chapter, note: note, items: items)
    }

    // MARK: Text

    /// Words in a note body. Markdown heading markers are not prose, so a
    /// token starting with `#` does not count.
    public static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { !$0.hasPrefix("#") }
            .count
    }

    /// The file-name slug for a chapter title: lowercase, runs of anything
    /// outside `[a-z0-9]` collapsed to a single dash, trimmed, 48 characters.
    public static func slugify(_ title: String) -> String {
        var slug: [Character] = []
        var pendingDash = false
        for character in title.lowercased() {
            if ("a"..."z").contains(character) || ("0"..."9").contains(character) {
                slug.append(character)
                pendingDash = false
            } else if !pendingDash {
                slug.append("-")
                pendingDash = true
            }
        }
        while slug.first == "-" { slug.removeFirst() }
        while slug.last == "-" { slug.removeLast() }
        return String(slug.prefix(48))
    }

    // MARK: Internals

    /// A parsed note file: frontmatter, long-form body, and the marks
    /// section blocks (marks plus any verbatim-preserved raw content).
    struct NoteFile {
        var frontmatter: NoteFrontmatter
        var body: String
        var items: [MarkItem]
    }

    /// A chapter note that has no file yet: blank body, no marks.
    static func blankNote(bookId: String, chapter: ChapterMeta) -> ChapterNote {
        ChapterNote(
            frontmatter: NoteFrontmatter(
                bookId: bookId,
                chapterKey: chapter.key,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                chapterHref: chapter.href,
                kind: "summary",
                wordCount: 0
            ),
            body: "",
            marks: [],
            path: ""
        )
    }

    static func parseNoteContent(_ raw: String, chapterKey: String) throws -> NoteFile {
        let (yaml, content) = try splitFrontmatter(raw)
        var frontmatter = try Frontmatter.decode(yaml)
        frontmatter.chapterKey = chapterKey
        let split = Marks.splitBody(content)
        var body = Substring(split.body)
        while body.hasPrefix("\n") { body = body.dropFirst() }
        return NoteFile(
            frontmatter: frontmatter,
            body: String(body),
            items: split.section.map(Marks.parseSection) ?? []
        )
    }

    /// Splits `---\n…\n---\n` off the front of a note file.
    private static func splitFrontmatter(_ raw: String) throws -> (yaml: String, content: String) {
        guard raw.hasPrefix("---\n") else {
            throw CoreError.notes("note file missing YAML frontmatter")
        }
        let afterOpen = raw.index(raw.startIndex, offsetBy: 4)
        // The first `\n---` after the opening fence closes it, matching the
        // non-greedy Rust regex; the newline after it, if any, is the fence's.
        guard let close = raw.range(of: "\n---", range: afterOpen..<raw.endIndex) else {
            throw CoreError.notes("note file missing YAML frontmatter")
        }
        var contentStart = close.upperBound
        if contentStart < raw.endIndex, raw[contentStart] == "\n" {
            contentStart = raw.index(after: contentStart)
        }
        return (String(raw[afterOpen..<close.lowerBound]), String(raw[contentStart...]))
    }

    private static func render(
        frontmatter: NoteFrontmatter, body: String, items: [MarkItem]
    ) -> String {
        var content = "---\n\(Frontmatter.encode(frontmatter))---\n\n\(body)"
        if !items.isEmpty {
            content += "\n\n\(Marks.serialize(items))"
        }
        return content
    }

    static func readMeta(bookDir: String) throws -> BookMeta {
        let path = bookDir.appendingPathComponent("meta.json")
        do {
            return try MarginsJSON.decode(BookMeta.self, from: FileStore.readData(path))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.notes("json error: \(error.localizedDescription)")
        }
    }

    /// Canonical path (relative to the notes dir) for a chapter's note file:
    /// the indexed file when present, else the name the note would get.
    private static func noteRelativePath(bookDir: String, chapter: ChapterMeta) throws -> String {
        if let entry = try readIndex(bookDir: bookDir).chapters
            .first(where: { $0.chapterKey == chapter.key }) {
            return entry.file
        }
        return "chapters/\(chapter.key)-\(slugify(chapter.title)).md"
    }

    /// Reads and parses the chapter's note file, if it exists.
    private static func readNoteFile(
        bookDir: String, chapter: ChapterMeta
    ) throws -> NoteFile? {
        let path = bookDir.appendingPathComponent("notes")
            .appendingPathComponent(try noteRelativePath(bookDir: bookDir, chapter: chapter))
        guard FileStore.isFile(path) else { return nil }
        return try parseNoteContent(try FileStore.read(path), chapterKey: chapter.key)
    }

    private static func writeNoteFile(
        bookDir: String,
        chapter: ChapterMeta,
        frontmatter: NoteFrontmatter,
        body: String,
        items: [MarkItem]
    ) throws {
        let notesDir = bookDir.appendingPathComponent("notes")
        try Files.createDirectory(notesDir.appendingPathComponent("chapters"))
        let path = notesDir
            .appendingPathComponent(try noteRelativePath(bookDir: bookDir, chapter: chapter))
        try FileStore.write(render(frontmatter: frontmatter, body: body, items: items), to: path)
    }

    /// Re-writes a note file after a mark-only mutation: body, word count,
    /// and `createdAt` are untouched; `updatedAt` and the index entry move
    /// forward.
    private static func rewriteKeepingBody(
        bookDir: String, chapter: ChapterMeta, note: NoteFile, items: [MarkItem]
    ) throws {
        var frontmatter = note.frontmatter
        frontmatter.updatedAt = RFC3339.now()
        try writeNoteFile(
            bookDir: bookDir, chapter: chapter,
            frontmatter: frontmatter, body: note.body, items: items
        )
        try upsertIndexEntry(
            bookDir: bookDir,
            chapter: chapter,
            file: try noteRelativePath(bookDir: bookDir, chapter: chapter),
            wordCount: frontmatter.wordCount,
            markCount: Marks.marks(items).count,
            updatedAt: frontmatter.updatedAt
        )
    }

    /// Adds or replaces the index entry for `chapter`, keeping the index
    /// sorted by chapter index, and writes it back.
    private static func upsertIndexEntry(
        bookDir: String,
        chapter: ChapterMeta,
        file: String,
        wordCount: Int,
        markCount: Int,
        updatedAt: Date?
    ) throws {
        let notesDir = bookDir.appendingPathComponent("notes")
        var index = try readIndex(bookDir: bookDir)
        index.chapters.removeAll { $0.chapterKey == chapter.key }
        index.chapters.append(
            NotesIndexEntry(
                chapterKey: chapter.key,
                file: file,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                wordCount: wordCount,
                markCount: markCount,
                updatedAt: updatedAt
            )
        )
        // Stable, so entries sharing a chapter index keep insertion order.
        index.chapters = index.chapters.enumerated()
            .sorted { ($0.element.chapterIndex, $0.offset) < ($1.element.chapterIndex, $1.offset) }
            .map(\.element)
        try FileStore.writeData(
            MarginsJSON.encode(index), to: notesDir.appendingPathComponent("_index.json")
        )
    }
}
