import CryptoKit
import Foundation

// The library tree: import, catalog, reading positions, bookmarks, removal
// (docs/storage.md). A book directory is named by a content hash of its
// EPUB, so importing the same file twice is idempotent, and it is assembled
// in a hidden staging directory and renamed into place, so an interrupted
// import can never appear as a book.

public final class Library {
    /// Schema version of `BookMeta.chapters`. Bumped whenever chapter
    /// metadata gains information the parser can now recover from the source
    /// EPUB (v1: TOC-derived titles and start fragments; v2: matter
    /// classification, outline levels, and every TOC entry per file); the
    /// library scan re-parses any book below it. Chapter keys are
    /// spine-derived and stay stable across re-parses, so notes keep
    /// resolving.
    public static let chaptersVersion = 2

    public private(set) var root: String
    private let search = SearchEngine()

    public init(root: String) throws {
        self.root = root
        try Self.prepare(root)
    }

    public func setRoot(_ root: String) throws {
        try Self.prepare(root)
        self.root = root
        // The cached index refers to the previous root; the next query
        // rebuilds it against the new one.
        search.clear()
    }

    private static func prepare(_ root: String) throws {
        try Files.createDirectory(root)
        try Files.createDirectory(root.appendingPathComponent("books"))
    }

    public func bookDir(_ bookID: String) -> String {
        root.appendingPathComponent("books").appendingPathComponent(bookID)
    }

    // MARK: The catalog

    public func listBooks() throws -> [BookSummary] {
        let booksDir = root.appendingPathComponent("books")
        guard Files.exists(booksDir) else { return [] }

        var summaries: [BookSummary] = []
        for path in try Files.contents(ofDirectory: booksDir) {
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix("."), Files.isDirectory(path) else { continue }
            let metaPath = path.appendingPathComponent("meta.json")
            guard FileStore.exists(metaPath) else { continue }

            var meta = try readMeta(at: metaPath)
            backfillChapters(bookDir: path, meta: &meta)
            summaries.append(
                BookSummary(
                    id: meta.id,
                    title: meta.title,
                    author: meta.author,
                    addedAt: meta.addedAt,
                    chapterCount: meta.chapters.count,
                    notesCount: try Notes.countNotes(bookDir: path),
                    cover: meta.cover ?? backfillCover(bookDir: path, meta: meta),
                    progressPercent: readPosition(bookID: meta.id)?.percent
                )
            )
        }

        summaries.sort { $0.addedAt > $1.addedAt }
        try writeIndex(summaries)
        return summaries.map(resolvingCover)
    }

    public func getBook(id: String) throws -> BookMeta {
        let metaPath = bookDir(id).appendingPathComponent("meta.json")
        guard FileStore.exists(metaPath) else {
            throw CoreError.library("book not found: \(id)")
        }
        var meta = try readMeta(at: metaPath)
        meta.progressPercent = readPosition(bookID: id)?.percent
        return resolvingCover(meta)
    }

    public func removeBook(id: String) throws {
        let dir = bookDir(id)
        if Files.exists(dir) { try Files.remove(dir) }
    }

    // MARK: Reading position

    /// The book's saved reading position, or `nil` when it was never opened
    /// or the position file is missing/corrupt (a corrupt file must not
    /// break the library — the reader falls back to chapter 1).
    public func readPosition(bookID: String) -> ReadingPosition? {
        let path = bookDir(bookID).appendingPathComponent("position.json")
        guard let data = try? FileStore.readData(path) else { return nil }
        return try? MarginsJSON.decode(ReadingPosition.self, from: data)
    }

    /// Saves the book's reading position. Percent is clamped to 0–100 and
    /// the save time is stamped here; any caller value is advisory.
    public func writePosition(bookID: String, position: ReadingPosition) throws {
        let dir = bookDir(bookID)
        guard Files.isDirectory(dir) else {
            throw CoreError.library("book not found: \(bookID)")
        }
        var position = position
        position.percent = min(max(position.percent, 0), 100)
        position.updatedAt = RFC3339.now()
        try FileStore.writeData(
            MarginsJSON.encode(position), to: dir.appendingPathComponent("position.json")
        )
    }

    // MARK: Bookmarks

    /// Named location pins for the book. A missing or corrupt file is an
    /// empty list — same posture as a missing `position.json`.
    public func readBookmarks(bookID: String) -> [Bookmark] {
        let path = bookDir(bookID).appendingPathComponent("bookmarks.json")
        guard let data = try? FileStore.readData(path) else { return [] }
        guard let file = try? MarginsJSON.decode(BookmarkFile.self, from: data) else {
            return []
        }
        return Bookmark.sortedForDisplay(file.bookmarks)
    }

    /// Drops a pin at `position`. Empty `label` is untitled. Percent is
    /// clamped; the core stamps created/updated.
    @discardableResult
    public func addBookmark(
        bookID: String, label: String, position: ReadingPosition
    ) throws -> Bookmark {
        var bookmarks = readBookmarks(bookID: bookID)
        let taken = Set(bookmarks.map(\.id))
        var id = CoreID.newID()
        while taken.contains(id) { id = CoreID.newID() }
        let now = RFC3339.now()
        let bookmark = Bookmark(
            id: id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            chapterKey: position.chapterKey,
            epubCfi: position.epubCfi.flatMap { $0.isEmpty ? nil : $0 },
            percent: min(max(position.percent, 0), 100),
            createdAt: now,
            updatedAt: now
        )
        bookmarks.append(bookmark)
        try writeBookmarks(bookID: bookID, bookmarks: bookmarks)
        return bookmark
    }

    /// Renames and/or restamps an existing pin. `nil` fields stay as they are.
    @discardableResult
    public func updateBookmark(
        bookID: String, id: String, label: String?, position: ReadingPosition?
    ) throws -> Bookmark {
        var bookmarks = readBookmarks(bookID: bookID)
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            throw CoreError.library("bookmark not found: \(id)")
        }
        var bookmark = bookmarks[index]
        if let label {
            bookmark.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let position {
            bookmark.chapterKey = position.chapterKey
            bookmark.epubCfi = position.epubCfi.flatMap { $0.isEmpty ? nil : $0 }
            bookmark.percent = min(max(position.percent, 0), 100)
        }
        bookmark.updatedAt = RFC3339.now()
        bookmarks[index] = bookmark
        try writeBookmarks(bookID: bookID, bookmarks: bookmarks)
        return bookmark
    }

    public func deleteBookmark(bookID: String, id: String) throws {
        var bookmarks = readBookmarks(bookID: bookID)
        let before = bookmarks.count
        bookmarks.removeAll { $0.id == id }
        guard bookmarks.count != before else {
            throw CoreError.library("bookmark not found: \(id)")
        }
        try writeBookmarks(bookID: bookID, bookmarks: bookmarks)
    }

    private func writeBookmarks(bookID: String, bookmarks: [Bookmark]) throws {
        let dir = bookDir(bookID)
        guard Files.isDirectory(dir) else {
            throw CoreError.library("book not found: \(bookID)")
        }
        let path = dir.appendingPathComponent("bookmarks.json")
        if bookmarks.isEmpty {
            if FileStore.exists(path) { try FileStore.remove(path) }
            return
        }
        try FileStore.writeData(
            MarginsJSON.encode(BookmarkFile(bookmarks: Bookmark.sortedForDisplay(bookmarks))),
            to: path
        )
    }

    public func readEpubBytes(bookID: String) throws -> Data {
        try Self.readEpubBytes(bookId: bookID, root: root)
    }

    /// Root-parameterized byte read. Exists for `CoreStore.readEpubBytesSync`,
    /// which the reader's scheme handler calls from WebKit threads — off the
    /// actor, so it carries the root with the call instead of reading the
    /// instance's.
    public static func readEpubBytes(bookId bookID: String, root: String) throws -> Data {
        let path = root.appendingPathComponent("books").appendingPathComponent(bookID)
            .appendingPathComponent("source.epub")
        guard Files.exists(path) else {
            throw CoreError.library("epub missing for book: \(bookID)")
        }
        return try Files.readData(path)
    }

    // MARK: Import

    /// Copies an EPUB into the library and records its metadata.
    ///
    /// `progress` is called with a percentage and a stage name; the import
    /// UIs show both. The work is assembled under `.{id}.importing-{uuid}`
    /// and renamed into place at the end, so a crash mid-import leaves a
    /// hidden directory the catalog ignores rather than a half-formed book.
    @discardableResult
    public func importEpub(
        atPath sourcePath: String,
        progress: (Int, String) -> Void = { _, _ in }
    ) throws -> BookMeta {
        progress(0, "preparing")
        guard Files.exists(sourcePath) else {
            throw CoreError.library("source file does not exist")
        }

        progress(5, "reading-metadata")
        let info = try EpubParser.parse(path: sourcePath)

        progress(30, "hashing")
        let bookID = try hashFile(sourcePath) { processed, total in
            progress(percentBetween(30, 50, processed, total), "hashing")
        }
        let finalDir = bookDir(bookID)

        if FileStore.isFile(finalDir.appendingPathComponent("meta.json")),
           Files.isFile(finalDir.appendingPathComponent("source.epub")) {
            let existing = try getBook(id: bookID)
            progress(100, "already-imported")
            return existing
        }

        let staging = root.appendingPathComponent("books")
            .appendingPathComponent(".\(bookID).importing-\(UUID().uuidString)")
        var committed = false
        defer { if !committed { try? Files.remove(staging) } }

        progress(55, "copying")
        try Files.createDirectory(staging.appendingPathComponent("notes/chapters"))
        try copyFile(
            from: sourcePath, to: staging.appendingPathComponent("source.epub")
        ) { processed, total in
            progress(percentBetween(55, 94, processed, total), "copying")
        }

        // A cover is a nice-to-have: a failed write must not fail the
        // import, so the meta records the name only on success.
        var coverName = info.cover.map { "cover.\($0.fileExtension)" }
        if let cover = info.cover, let name = coverName {
            do {
                try Files.writeData(cover.bytes, to: staging.appendingPathComponent(name))
            } catch {
                coverName = nil
            }
        }

        let meta = BookMeta(
            id: bookID,
            title: info.title,
            author: info.author,
            language: info.language,
            addedAt: RFC3339.now(),
            sourceFilename: (sourcePath as NSString).lastPathComponent,
            chapters: info.chapters,
            cover: coverName,
            chaptersVersion: Self.chaptersVersion
        )

        progress(95, "saving")
        try FileStore.writeData(
            MarginsJSON.encode(meta), to: staging.appendingPathComponent("meta.json")
        )
        progress(97, "saving")
        try Notes.writeEmptyIndex(bookDir: staging)
        progress(99, "saving")
        try writeBookReadme(bookDir: staging, meta: meta)

        if Files.exists(finalDir) {
            // A previous interrupted import can leave an incomplete final
            // directory. Remove it only after the source has been copied
            // into staging.
            try Files.remove(finalDir)
        }
        try Files.rename(staging, to: finalDir)
        committed = true

        progress(100, "complete")
        return resolvingCover(meta)
    }

    // MARK: Search

    public func searchNotes(query: String) -> [NoteSearchHit] {
        search.query(root: root, raw: query)
    }

    /// Updates the search index for one book in place after a save.
    public func refreshNoteIndex(bookID: String) {
        search.refreshBook(root: root, bookID: bookID)
    }

    // MARK: Backfills

    /// Re-derives chapter metadata for books imported under an older parser
    /// (`chaptersVersion` below the current one) by re-reading the retained
    /// `source.epub`. The spine is unchanged, so keys keep pointing at the
    /// same notes and `position.json`; only titles and start fragments
    /// improve. A missing or corrupt source leaves the book exactly as it
    /// was — a bad EPUB must never break the library scan.
    private func backfillChapters(bookDir: String, meta: inout BookMeta) {
        guard meta.chaptersVersion < Self.chaptersVersion else { return }
        let source = bookDir.appendingPathComponent("source.epub")
        guard Files.isFile(source), let info = try? EpubParser.parse(path: source) else { return }

        meta.chapters = info.chapters
        meta.chaptersVersion = Self.chaptersVersion
        try? FileStore.writeData(
            MarginsJSON.encode(meta), to: bookDir.appendingPathComponent("meta.json")
        )
    }

    /// One-shot cover backfill for books imported before covers were
    /// extracted: pulls the cover out of the retained `source.epub`, writes
    /// it into the book directory, and records the file name in `meta.json`.
    /// Books whose EPUB has no cover are re-probed on each scan (a cheap zip
    /// central-directory read at personal-library scale).
    private func backfillCover(bookDir: String, meta: BookMeta) -> String? {
        let source = bookDir.appendingPathComponent("source.epub")
        guard Files.isFile(source), let cover = EpubParser.extractCover(path: source) else {
            return nil
        }
        let name = "cover.\(cover.fileExtension)"
        guard (try? Files.writeData(cover.bytes, to: bookDir.appendingPathComponent(name))) != nil
        else { return nil }

        var updated = meta
        updated.cover = name
        try? FileStore.writeData(
            MarginsJSON.encode(updated), to: bookDir.appendingPathComponent("meta.json")
        )
        return name
    }

    // MARK: Writing

    private func writeIndex(_ summaries: [BookSummary]) throws {
        try Files.writeData(
            MarginsJSON.encode(LibraryIndex(books: summaries)),
            to: root.appendingPathComponent("index.json")
        )
    }

    private func writeBookReadme(bookDir: String, meta: BookMeta) throws {
        let readme = """
        # \(meta.title)

        Author: \(meta.author)
        Book ID: `\(meta.id)`

        ## Notes layout

        Chapter summaries and annotations live in `notes/chapters/` as \
        Markdown files with YAML frontmatter. Each file is self-contained \
        and agent-friendly.

        - `meta.json` — book metadata and chapter spine
        - `notes/_index.json` — machine-readable note index
        - `notes/chapters/*.md` — one file per chapter note
        - `source.epub` — imported EPUB copy

        """
        try Files.write(readme, to: bookDir.appendingPathComponent("README.md"))
    }

    private func readMeta(at path: String) throws -> BookMeta {
        do {
            return try MarginsJSON.decode(BookMeta.self, from: FileStore.readData(path))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.library("json error: \(error.localizedDescription)")
        }
    }

    /// Fills in the absolute cover path callers display from. The stored
    /// `cover` stays a bare file name so the tree is portable.
    private func resolvingCover(_ meta: BookMeta) -> BookMeta {
        var meta = meta
        meta.coverPath = meta.cover.map { bookDir(meta.id).appendingPathComponent($0) }
        return meta
    }

    private func resolvingCover(_ summary: BookSummary) -> BookSummary {
        var summary = summary
        summary.coverPath = summary.cover.map { bookDir(summary.id).appendingPathComponent($0) }
        return summary
    }
}

// MARK: - File work

/// The book id: the first 12 bytes of the EPUB's SHA-256, hex-encoded — 24
/// characters, enough to make a collision in a personal library impossible
/// and short enough to type.
func hashFile(_ path: String, progress: (Int64, Int64) -> Void) throws -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        throw CoreError.io("io error: could not read \(path)")
    }
    defer { try? handle.close() }

    let total = fileSize(path)
    var hasher = SHA256()
    var processed: Int64 = 0
    progress(processed, total)

    while let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty {
        hasher.update(data: chunk)
        processed += Int64(chunk.count)
        progress(processed, total)
    }
    return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
}

/// Streams a copy so the import UI can show real progress on a large book.
func copyFile(from source: String, to destination: String, progress: (Int64, Int64) -> Void) throws {
    guard let reader = FileHandle(forReadingAtPath: source) else {
        throw CoreError.io("io error: could not read \(source)")
    }
    defer { try? reader.close() }

    guard FileManager.default.createFile(atPath: destination, contents: nil),
          let writer = FileHandle(forWritingAtPath: destination)
    else {
        throw CoreError.io("io error: could not write \(destination)")
    }
    defer { try? writer.close() }

    let total = fileSize(source)
    var processed: Int64 = 0
    progress(processed, total)

    while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
        do {
            try writer.write(contentsOf: chunk)
        } catch {
            throw CoreError.io("io error: could not write \(destination)")
        }
        processed += Int64(chunk.count)
        progress(processed, total)
    }
}

private func fileSize(_ path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Maps byte progress onto a slice of the overall percentage.
func percentBetween(_ start: Int, _ end: Int, _ processed: Int64, _ total: Int64) -> Int {
    guard total > 0 else { return end }
    let range = max(end - start, 0)
    return start + Int(Int64(range) * min(processed, total) / total)
}
