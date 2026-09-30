import Foundation

/// Actor facade over the Swift core — what the apps talk to.
///
/// The core's entry points are synchronous and do real file I/O (notably
/// `importEpub`), so calls must stay off the main actor. `AppConfig` and
/// `Library` live inside the actor and every call is funneled through the
/// actor's executor; `Library` in turn owns the `SearchEngine`.
public actor CoreStore {
    private var config: AppConfig
    private let library: Library
    private let clubs: ClubStore
    /// The plain-file full-text index under the app data dir.
    private let textIndex: TextIndex
    /// Books currently indexing — a second `indexBookText` returns false.
    private var indexingBooks: Set<String> = []

    /// The library root as `readEpubBytesSync` sees it. That call must not
    /// hop through the actor (the reader's scheme handler invokes it
    /// synchronously from WebKit threads), so the root it reads is carried
    /// outside actor isolation behind a lock and kept in step by
    /// `setLibraryRoot`.
    private nonisolated let readerRoot = ReaderRoot("")

    private final class ReaderRoot: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String

        init(_ path: String) {
            self.path = path
        }

        var current: String {
            get { lock.withLock { path } }
            set { lock.withLock { path = newValue } }
        }
    }

    /// - Parameter dataDir: explicit data directory, or `nil` to let the core
    ///   resolve `MARGINS_DATA_DIR` / the platform default.
    public init(dataDir: String?) throws {
        let config = try AppConfig(dataDir: dataDir)
        self.config = config
        self.library = try Library(root: config.libraryRoot)
        self.clubs = ClubStore(root: config.dataDir.appendingPathComponent("clubs"))
        self.textIndex = TextIndex(
            directory: config.dataDir.appendingPathComponent("text-index"))
        readerRoot.current = config.libraryRoot
    }

    public func dataDir() throws -> String {
        config.dataDir
    }

    public func libraryRoot() throws -> String {
        library.root
    }

    public func setLibraryRoot(path: String) throws {
        let previous = library.root
        try library.setRoot(path)
        do {
            try config.setLibraryRoot(path)
        } catch let configError {
            // A failed save must not leave the two halves pointing at
            // different roots; restore the active library first.
            do {
                try library.setRoot(previous)
            } catch let restoreError {
                throw CoreError.config(
                    "could not save library directory: \(Self.message(of: configError)); "
                        + "could not restore active directory: \(Self.message(of: restoreError))"
                )
            }
            throw configError
        }
        readerRoot.current = path
    }

    /// The core only ever throws `CoreError`; this keeps the message even if
    /// a future wrapped error leaks through.
    private static func message(of error: any Error) -> String {
        (error as? CoreError)?.message ?? error.localizedDescription
    }

    public func listBooks() throws -> [BookSummary] {
        try library.listBooks()
    }

    public func notDownloadedBookIDs() -> [String] {
        library.notDownloadedBookIDs()
    }

    public func importEpub(atPath path: String) throws -> BookMeta {
        try library.importEpub(atPath: path)
    }

    public func getBook(id: String) throws -> BookMeta {
        try library.getBook(id: id)
    }

    public func removeBook(id: String) throws {
        try library.removeBook(id: id)
        // The index is derived — a failed cleanup leaves nothing but a
        // stray directory, which the next reconcile drops.
        try? textIndex.remove(bookId: id)
    }

    /// Deletes every note file for the book and resets its notes index;
    /// returns the number of note files removed.
    public func clearNotes(bookId: String) throws -> Int {
        let bookDir = library.bookDir(bookId)
        guard Files.isDirectory(bookDir) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        let cleared = try Notes.clearBookNotes(bookDir: bookDir)
        // Keep the search index warm: update this book's docs in place.
        library.refreshNoteIndex(bookID: bookId)
        return cleared
    }

    /// The book's saved reading position, or `nil` when it was never opened.
    public func readingPosition(bookId: String) throws -> ReadingPosition? {
        library.readPosition(bookID: bookId)
    }

    /// Persists the book's reading position into the library tree.
    public func saveReadingPosition(bookId: String, position: ReadingPosition) throws {
        try library.writePosition(bookID: bookId, position: position)
    }

    /// Named location pins for the book; empty when none have been dropped.
    public func bookmarks(bookId: String) throws -> [Bookmark] {
        library.readBookmarks(bookID: bookId)
    }

    @discardableResult
    public func addBookmark(
        bookId: String, label: String, position: ReadingPosition
    ) throws -> Bookmark {
        try library.addBookmark(bookID: bookId, label: label, position: position)
    }

    @discardableResult
    public func updateBookmark(
        bookId: String, id: String, label: String?, position: ReadingPosition?
    ) throws -> Bookmark {
        try library.updateBookmark(bookID: bookId, id: id, label: label, position: position)
    }

    public func deleteBookmark(bookId: String, id: String) throws {
        try library.deleteBookmark(bookID: bookId, id: id)
    }

    /// Synchronous, thread-safe EPUB byte access for the reader's scheme
    /// handler, which runs on WebKit-owned threads: the path comes from the
    /// lock-guarded root above, never from actor state.
    public nonisolated func readEpubBytesSync(id: String) throws -> Data {
        try Library.readEpubBytes(bookId: id, root: readerRoot.current)
    }

    public func getChapterNote(bookId: String, chapterKey: String) throws -> ChapterNote {
        try Notes.loadChapterNote(
            bookDir: library.bookDir(bookId), chapterKey: chapterKey
        )
    }

    /// The book's notes index (`notes/_index.json`): which chapters have
    /// notes, with word counts. Empty when the book has no notes.
    public func notesIndex(bookId: String) throws -> [NotesIndexEntry] {
        let bookDir = library.bookDir(bookId)
        guard Files.isDirectory(bookDir) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        do {
            return try Notes.readIndex(bookDir: bookDir).chapters
        } catch let error as CoreError {
            guard case .notDownloaded = error else { throw error }
            return []
        }
    }

    /// The book's notes compiled into one spine-ordered document.
    public func compiledNotes(bookId: String) throws -> CompiledNotes {
        let bookDir = library.bookDir(bookId)
        guard FileStore.exists(bookDir.appendingPathComponent("meta.json")) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        return try Compile.bookNotes(bookDir: bookDir)
    }

    /// Renders the book's notes as markdown (the export/copy payload).
    /// `options` of `nil` uses the core defaults.
    public func renderNotesMarkdown(bookId: String, options: ExportOptions?) throws -> String {
        let bookDir = library.bookDir(bookId)
        guard FileStore.exists(bookDir.appendingPathComponent("meta.json")) else {
            throw CoreError.library("book not found: \(bookId)")
        }
        let compiled = try Compile.bookNotes(bookDir: bookDir)
        return Compile.renderMarkdown(compiled, options: options ?? .default)
    }

    public func saveChapterNote(
        bookId: String,
        chapter: ChapterRef,
        body: String,
        kind: String?
    ) throws -> ChapterNote {
        let bookDir = library.bookDir(bookId)
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapter.key)
        let frontmatter = NoteFrontmatter(
            bookId: bookId,
            chapterKey: chapterMeta.key,
            chapterIndex: chapterMeta.index,
            chapterTitle: chapterMeta.title,
            chapterHref: chapterMeta.href,
            epubCfi: chapter.epubCfi,
            kind: kind ?? "summary",
            wordCount: Notes.countWords(body)
        )
        let saved = try Notes.saveChapterNote(
            bookDir: bookDir, chapter: chapterMeta, frontmatter: frontmatter, body: body
        )
        // Keep the search index warm: update this book's docs in place.
        library.refreshNoteIndex(bookID: bookId)
        return saved
    }

    /// Appends a quick mark to the chapter's note file (creating the file
    /// when the chapter has no note yet); the core assigns id + timestamp.
    @discardableResult
    public func appendMark(
        bookId: String,
        chapterKey: String,
        cfi: String?,
        percent: Double?,
        quote: String,
        body: String
    ) throws -> Mark {
        let bookDir = library.bookDir(bookId)
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapterKey)
        let mark = try Notes.appendMark(
            bookDir: bookDir,
            chapter: chapterMeta,
            cfi: cfi,
            percent: percent,
            quote: quote,
            body: body
        )
        library.refreshNoteIndex(bookID: bookId)
        return mark
    }

    /// Replaces the mark (matched by id) in the chapter's note file.
    public func updateMark(bookId: String, chapterKey: String, mark: Mark) throws {
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapterKey)
        try Notes.updateMark(
            bookDir: library.bookDir(bookId), chapter: chapterMeta, mark: mark
        )
        library.refreshNoteIndex(bookID: bookId)
    }

    /// Removes the mark with `markId` from the chapter's note file.
    public func deleteMark(bookId: String, chapterKey: String, markId: String) throws {
        let chapterMeta = try resolveChapter(bookId: bookId, chapterKey: chapterKey)
        try Notes.deleteMark(
            bookDir: library.bookDir(bookId), chapter: chapterMeta, id: markId
        )
        library.refreshNoteIndex(bookID: bookId)
    }

    public func searchNotes(query: String) throws -> [NoteSearchHit] {
        library.searchNotes(query: query)
    }

    // MARK: Full-text index

    /// Searches the plain-file index over the books in the current
    /// library; titles/authors/chapter titles are joined from meta.json.
    public func searchBookText(query: String, limit: Int = 50) throws -> [TextSearchHit] {
        try textIndex.ensure()
        let scored = try textIndex.search(
            query: query, bookIds: library.presentBookIDs(), limit: limit)
        var metas: [String: BookMeta] = [:]
        for hit in scored where metas[hit.bookId] == nil {
            metas[hit.bookId] = try? library.getBook(id: hit.bookId)
        }
        return scored.compactMap { hit in
            guard let meta = metas[hit.bookId] else { return nil }
            let chapter = meta.chapters.first { $0.key == hit.chapterKey }
            return TextSearchHit(
                bookId: hit.bookId, bookTitle: meta.title, bookAuthor: meta.author,
                chapterKey: hit.chapterKey, chapterIndex: chapter?.index ?? 0,
                chapterTitle: chapter?.title ?? hit.chapterKey,
                passage: hit.passage, passageIndex: hit.passageIndex,
                snippet: hit.snippet, snippetRanges: hit.snippetRanges, score: hit.score
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.bookTitle != rhs.bookTitle {
                return lhs.bookTitle.localizedStandardCompare(rhs.bookTitle) == .orderedAscending
            }
            if lhs.chapterIndex != rhs.chapterIndex { return lhs.chapterIndex < rhs.chapterIndex }
            return lhs.passageIndex < rhs.passageIndex
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Builds (or refreshes) the book's full-text index. `epubPath`
    /// defaults to the library's `books/{id}/source.epub` — an evicted
    /// placeholder throws `CoreError.notDownloaded`. Extraction runs off
    /// the actor and is committed atomically; a concurrent build of the
    /// same book returns `false`.
    public func indexBookText(bookId: String, epubPath: String? = nil) async throws -> Bool {
        try textIndex.ensure()
        let meta = try library.getBook(id: bookId)
        guard !textIndex.isCurrent(bookId: bookId, chaptersVersion: meta.chaptersVersion)
        else { return false }
        guard indexingBooks.insert(bookId).inserted else { return false }
        defer { indexingBooks.remove(bookId) }

        let epub: String
        if let epubPath {
            epub = epubPath
        } else {
            let path = library.bookDir(bookId).appendingPathComponent("source.epub")
            guard !FileStore.isEvicted(path) else {
                throw CoreError.notDownloaded(path)
            }
            epub = path
        }
        let staging = config.dataDir
            .appendingPathComponent("text-index/books/.staging-\(UUID().uuidString)")
        try await Task.detached(priority: .utility) {
            try TextIndex.build(bookId: bookId, epubPath: epub, meta: meta, into: staging)
        }.value
        try textIndex.commit(stagingDir: staging, bookId: bookId)
        return true
    }

    /// Which of the current library's books are full-text indexed.
    public func textIndexStatus() throws -> TextIndexStatus {
        try textIndex.ensure()
        let ids = library.presentBookIDs()
        let indexed = textIndex.indexedBookIds().intersection(ids).sorted()
        return TextIndexStatus(
            indexedBookIds: indexed,
            pendingBookIds: ids.subtracting(indexed).sorted()
        )
    }

    /// Deletes the whole index directory; the next query recreates it.
    public func deleteTextIndex() throws {
        try textIndex.reset()
    }

    // MARK: Notebooks

    /// The notebook catalog (`notebooks/_index.json`), newest first.
    public func listNotebooks() throws -> [NotebookSummary] {
        try library.listNotebooks()
    }

    /// Creates an empty notebook; an empty title is an error.
    public func createNotebook(title: String) throws -> NotebookSummary {
        try library.createNotebook(title: title)
    }

    /// Renames the notebook and moves its file to the new slug.
    public func renameNotebook(id: String, title: String) throws -> NotebookSummary {
        try library.renameNotebook(id: id, title: title)
    }

    public func deleteNotebook(id: String) throws {
        try library.deleteNotebook(id: id)
    }

    /// Loads one notebook with passages resolved against the live library.
    public func notebook(id: String) throws -> Notebook {
        try library.notebook(id: id)
    }

    /// Saves the segment list the UI hands back; untouched passage blocks
    /// keep their bytes, a changed quote or citation is regenerated.
    public func saveNotebook(id: String, segments: [NotebookSegment]) throws -> Notebook {
        try library.saveNotebook(id: id, segments: segments)
    }

    /// Appends a passage (existing mark, or a selection the core turns
    /// into a mark first) plus optional commentary prose.
    public func addPassage(
        notebookId: String, source: PassageSource, commentary: String
    ) throws -> Notebook {
        try library.addPassage(notebookId: notebookId, source: source, commentary: commentary)
    }

    /// markId → the notebooks citing it, for one book.
    public func notebooksCiting(bookId: String) throws -> [String: [NotebookSummary]] {
        try library.notebooksCiting(bookId: bookId)
    }

    // MARK: Clubs

    /// Creates a private club reading `bookId`, with the creator as admin.
    /// The book must be in the library.
    public func createClub(
        bookId: String, name: String, adminId: String, adminName: String
    ) throws -> Club {
        let book = try library.getBook(id: bookId)
        return try clubs.createClub(
            name: name,
            bookId: book.id,
            bookTitle: book.title,
            bookAuthor: book.author,
            adminId: adminId,
            adminName: adminName
        )
    }

    public func listClubs() throws -> [Club] {
        try clubs.listClubs()
    }

    public func getClub(id: String) throws -> Club {
        try clubs.getClub(id: id)
    }

    /// Persists roster/name changes to an existing club.
    public func updateClub(_ club: Club) throws {
        try clubs.updateClub(club)
    }

    /// Stores a club record received from another device (join or sync).
    /// Unlike `updateClub`, this is an upsert: a joiner has no local record
    /// yet, and a sync must be able to adopt a roster it did not write.
    public func saveClub(_ club: Club) throws {
        try clubs.writeClub(club)
    }

    public func deleteClub(id: String) throws {
        try clubs.deleteClub(id: id)
    }

    /// Replaces the club's invite code and returns the new one.
    public func rotateClubInviteCode(clubId: String) throws -> String {
        try clubs.rotateInviteCode(clubId: clubId).inviteCode
    }

    /// Stores one member's snapshot over any previous one.
    public func saveClubMemberSnapshot(clubId: String, snapshot: ClubMemberNotes) throws {
        try clubs.writeMemberSnapshot(snapshot, clubId: clubId)
    }

    public func clubMemberSnapshots(clubId: String) throws -> [ClubMemberNotes] {
        try clubs.memberSnapshots(clubId: clubId)
    }

    /// Drops one member's local snapshot (admin removal, or a member whose
    /// snapshot was deleted remotely).
    public func removeClubMemberSnapshot(clubId: String, memberId: String) throws {
        try clubs.removeMemberSnapshot(clubId: clubId, memberId: memberId)
    }

    /// Rebuilds a member's snapshot from this device's notes for the club's
    /// book. The snapshot is derived; persist it with
    /// `saveClubMemberSnapshot` (or use `refreshClubMemberSnapshot`).
    public func buildClubMemberSnapshot(
        clubId: String, memberId: String, displayName: String
    ) throws -> ClubMemberNotes {
        let club = try clubs.getClub(id: clubId)
        let compiled = try Compile.bookNotes(bookDir: library.bookDir(club.bookId))
        return ClubCompile.snapshot(compiled, memberId: memberId, displayName: displayName)
    }

    /// Rebuilds and stores the member's snapshot in one step.
    @discardableResult
    public func refreshClubMemberSnapshot(
        clubId: String, memberId: String, displayName: String
    ) throws -> ClubMemberNotes {
        let snapshot = try buildClubMemberSnapshot(
            clubId: clubId, memberId: memberId, displayName: displayName
        )
        try clubs.writeMemberSnapshot(snapshot, clubId: clubId)
        return snapshot
    }

    /// The merged club view for `viewerId`, with spoiler gating applied for
    /// the viewer's current chapter in the club's book. `spoilerEnabled`
    /// overrides the saved setting (used by a temporary "reveal" control);
    /// `nil` reads the setting.
    public func clubNotes(
        clubId: String, viewerId: String, spoilerEnabled: Bool? = nil
    ) throws -> ClubNotes {
        let club = try clubs.getClub(id: clubId)
        let snapshots = try clubs.memberSnapshots(clubId: clubId)
        return ClubCompile.compile(
            club: club,
            snapshots: snapshots,
            viewerId: viewerId,
            viewerChapterIndex: currentChapterIndex(bookId: club.bookId),
            spoilerPolicy: SpoilerPolicy(
                isEnabled: spoilerEnabled ?? config.clubSpoilerProtection
            )
        )
    }

    /// Renders the merged club view as markdown (the export payload).
    public func renderClubNotesMarkdown(
        clubId: String, viewerId: String, spoilerEnabled: Bool? = nil,
        options: ClubExportOptions? = nil
    ) throws -> String {
        let notes = try clubNotes(
            clubId: clubId, viewerId: viewerId, spoilerEnabled: spoilerEnabled
        )
        return ClubCompile.renderMarkdown(notes, options: options ?? .default)
    }

    /// The saved club spoiler-protection setting (default `true`).
    public func clubSpoilerProtection() throws -> Bool {
        config.clubSpoilerProtection
    }

    public func setClubSpoilerProtection(_ enabled: Bool) throws {
        try config.setClubSpoilerProtection(enabled)
    }

    /// The local identity for club membership: a stable member id (generated
    /// once) plus the saved display name.
    public func clubIdentity() throws -> ClubIdentity {
        ClubIdentity(
            memberId: try config.ensureClubMemberId(),
            displayName: config.clubDisplayName
        )
    }

    /// Remembers the name to show other members.
    public func setClubDisplayName(_ name: String) throws {
        try config.setClubDisplayName(name)
    }

    /// Adopts the transport member id (a CloudKit user record name) as the
    /// local club identity. Clubs created under a different id are migrated
    /// — roster entries and snapshot files and contents — so a local-only
    /// club keeps being "you" after iCloud becomes available, and CloudKit
    /// participant records match the roster afterwards.
    public func adoptClubMemberId(_ memberId: String) throws {
        let previous = config.clubMemberId
        guard previous != memberId else { return }

        if let previous {
            for club in try clubs.listClubs() {
                var updated = club
                var changed = false
                if updated.ownerMemberId == previous {
                    updated.ownerMemberId = memberId
                    changed = true
                }
                for index in updated.members.indices
                where updated.members[index].id == previous {
                    updated.members[index].id = memberId
                    changed = true
                }
                if changed { try clubs.writeClub(updated) }

                if let snapshot = try clubs.memberSnapshot(
                    clubId: club.id, memberId: previous
                ) {
                    var migrated = snapshot
                    migrated.memberId = memberId
                    try clubs.writeMemberSnapshot(migrated, clubId: club.id)
                    try clubs.removeMemberSnapshot(clubId: club.id, memberId: previous)
                }
            }
        }
        try config.setClubMemberId(memberId)
    }

    /// The viewer's current spine index for the club's book, or `nil` when
    /// the book was never opened — which spoiler protection treats as
    /// "nothing read yet".
    private func currentChapterIndex(bookId: String) -> Int? {
        guard let position = library.readPosition(bookID: bookId),
            let meta = try? library.getBook(id: bookId),
            let chapter = meta.chapters.first(where: { $0.key == position.chapterKey })
        else { return nil }
        return chapter.index
    }

    /// The spine's chapter record for a key, or an error for unknown keys.
    private func resolveChapter(bookId: String, chapterKey: String) throws -> ChapterMeta {
        let meta = try library.getBook(id: bookId)
        guard let chapter = meta.chapters.first(where: { $0.key == chapterKey }) else {
            throw CoreError.notes("unknown chapter key: \(chapterKey)")
        }
        return chapter
    }
}
