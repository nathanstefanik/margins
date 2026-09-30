import Foundation
import MarginsCore
import MarginsModel
import Testing

@Suite("Library model")
struct LibraryModelTests {
    @Test("activate starts with an empty library and a resolved root")
    @MainActor
    func activateStartsEmpty() async throws {
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(model.books.isEmpty)
        #expect(model.notDownloadedBookIDs.isEmpty)
        #expect(!model.libraryRoot.isEmpty)
        #expect(model.selectedBookID == nil)
        #expect(model.selectedBook == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("import → selection → chapters through the model")
    @MainActor
    func importSelectsAndLoadsChapters() async throws {
        let fixtures = try fixtureEpubs()
        #expect(!fixtures.isEmpty, "expected at least one fixtures/*.epub")

        for fixture in fixtures {
            // A fresh library per fixture: each import is the first one it
            // has ever seen.
            let model = LibraryModel(dataDir: try makeTempDataDir())
            await model.activate()

            let imported = await model.importEpub(atPath: fixture)
            #expect(imported, "import failed: \(model.errorMessage ?? "no error")")
            #expect(model.errorMessage == nil)

            // The import refreshed the list and selected the new book.
            #expect(model.books.count == 1)
            #expect(model.selectedBookID != nil)

            let book = try #require(model.selectedBook)
            #expect(book.id == model.selectedBookID)
            #expect(!book.title.isEmpty)
            #expect(!book.author.isEmpty)
            #expect(!book.chapters.isEmpty)

            // Chapter count in the detail view agrees with the list summary.
            #expect(model.books.first?.chapterCount == book.chapters.count)
        }
    }

    @Test("openPassage carries an outline section fragment through to the reader")
    @MainActor
    func openPassageCarriesSectionFragment() async throws {
        let fixture =
            repoRoot
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("dostoyevsky_the_karamazov_brothers.epub")
            .path
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        // A file the TOC names twice, with a real anchor on its later entry.
        let chapter = try #require(
            book.chapters.first { $0.sections.count > 1 && $0.sections[1].fragment != nil }
        )
        let fragment = try #require(chapter.sections[1].fragment)

        let reader = ReaderModel()
        model.reader = reader
        await model.openPassage(
            bookId: book.id,
            chapterKey: chapter.key,
            cfi: nil,
            fragment: fragment
        )

        #expect(reader.chapter?.key == chapter.key)
        #expect(reader.displayTarget == "\(chapter.href)#\(fragment)")
        #expect(model.pendingReaderPresent)
    }

    @Test("openPassage arms a text reveal only when the hit has no CFI")
    @MainActor
    func openPassageArmsReveal() async throws {
        let fixture =
            repoRoot
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("h-g-wells_the-time-machine.epub")
            .path
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader

        // No CFI → the reveal is armed for the target chapter.
        await model.openPassage(
            bookId: book.id, chapterKey: book.chapters[0].key, cfi: nil,
            revealText: "the line to find", markId: "m42")
        #expect(
            reader.pendingReveal
                == ReaderModel.PassageReveal(
                    text: "the line to find", markId: "m42",
                    chapterKey: book.chapters[0].key))

        // A real CFI opens exactly — the reveal clears.
        await model.openPassage(
            bookId: book.id, chapterKey: book.chapters[0].key,
            cfi: "epubcfi(/6/2!/4/2)", revealText: "the line to find")
        #expect(reader.pendingReveal == nil)
        #expect(reader.resumeCfi == "epubcfi(/6/2!/4/2)")

        // Empty reveal text never arms it either.
        await model.openPassage(
            bookId: book.id, chapterKey: book.chapters[0].key, cfi: nil,
            revealText: "")
        #expect(reader.pendingReveal == nil)
    }

    @Test("backfillMarkCfi fills a missing cfi and never clobbers one")
    @MainActor
    func backfillMarkCfi() async throws {
        let fixture =
            repoRoot
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("h-g-wells_the-time-machine.epub")
            .path
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        let chapterKey = book.chapters[0].key

        let mark = try #require(
            await model.appendMark(
                bookId: book.id, chapterKey: chapterKey,
                cfi: nil, percent: nil, quote: "a quote worth finding",
                body: "", reader: reader))
        #expect(mark.cfi == nil)

        await model.backfillMarkCfi(
            bookId: book.id, chapterKey: chapterKey, markId: mark.id,
            cfi: "epubcfi(/6/4!/2/2)")
        // The mark gained its cfi on disk and in the open reader.
        let note = try await model.coreStore!.getChapterNote(
            bookId: book.id, chapterKey: chapterKey)
        #expect(note.marks.first { $0.id == mark.id }?.cfi == "epubcfi(/6/4!/2/2)")
        #expect(reader.noteMarks.first { $0.id == mark.id }?.cfi == "epubcfi(/6/4!/2/2)")

        // A second reveal must not clobber a real CFI.
        await model.backfillMarkCfi(
            bookId: book.id, chapterKey: chapterKey, markId: mark.id,
            cfi: "epubcfi(/6/8!/2/2)")
        let after = try await model.coreStore!.getChapterNote(
            bookId: book.id, chapterKey: chapterKey)
        #expect(after.marks.first { $0.id == mark.id }?.cfi == "epubcfi(/6/4!/2/2)")
    }

    @Test("remove clears selection and empties the library")
    @MainActor
    func removeBookClearsSelection() async throws {
        let fixtures = try fixtureEpubs()
        let fixture = try #require(fixtures.first)

        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()

        let imported = await model.importEpub(atPath: fixture)
        #expect(imported)
        let id = try #require(model.selectedBookID)

        await model.removeBook(id: id)

        #expect(model.books.isEmpty)
        #expect(model.selectedBookID == nil)
        #expect(model.selectedBook == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("clearNotes empties the index and resets the reader's editor")
    @MainActor
    func clearNotesResetsReaderEditor() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteBody = "a note about chapter one"
        await model.saveChapterNote(reader: reader)
        #expect(reader.notesError == nil)

        await model.loadSelectedBook()
        let countsBefore = LibraryModel.noteWordCounts(
            chapters: book.chapters,
            index: model.selectedBookNotesIndex
        )
        #expect(!countsBefore.isEmpty)

        let cleared = await model.clearNotes(bookId: book.id)
        #expect(cleared == 1)
        #expect(model.errorMessage == nil)
        #expect(model.selectedBookNotesIndex.isEmpty)

        // The reader's editor was reloaded from disk: blank body with a
        // clean baseline, so a later autosave cannot resurrect the note.
        #expect(reader.noteBody.isEmpty)
        #expect(!reader.isNoteDirty)

        // The refreshed book summary reflects zero notes.
        #expect(model.books.first?.notesCount == 0)
    }

    @Test("clearNotes recompiles a cached compiled notes page")
    @MainActor
    func clearNotesRefreshesCompiledPage() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteBody = "a note about chapter one"
        await model.saveChapterNote(reader: reader)
        #expect(reader.notesError == nil)

        await model.loadCompiledNotes(bookId: book.id)
        #expect(model.compiledNotes?.chaptersWithNotes == 1)
        #expect(model.detailMode == .notes)

        let cleared = await model.clearNotes(bookId: book.id)
        #expect(cleared == 1)
        #expect(model.errorMessage == nil)

        // The cached compiled page reflects the clear immediately — no
        // manual reload, no navigation away and back.
        let notes = try #require(model.compiledNotes)
        #expect(notes.bookId == book.id)
        #expect(notes.chaptersWithNotes == 0)
        #expect(notes.chapters.isEmpty)
        #expect(model.detailMode == .notes)
    }

    @Test("saving a note recompiles a stale compiled notes page")
    @MainActor
    func saveNoteRefreshesCompiledPage() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        await model.loadCompiledNotes(bookId: book.id)
        #expect(model.detailMode == .notes)
        #expect(model.compiledNotes?.chaptersWithNotes == 0)
        model.showNotesPageTab(.outline)

        // Opening a chapter from the notes page leaves the page mounted
        // underneath the reader (detailMode stays .notes).
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteBody = "a brand new observation"
        await model.saveChapterNote(reader: reader)
        #expect(reader.notesError == nil)

        // The save recompiled the page: outline and contents now include
        // the note, and the outline tab choice survived the reload.
        let notes = try #require(model.compiledNotes)
        #expect(notes.chaptersWithNotes == 1)
        #expect(notes.chapters.first?.body.contains("a brand new observation") == true)
        #expect(model.detailMode == .notes)
        #expect(model.notesPageTab == .outline)
    }

    @Test("import failure surfaces an error message")
    @MainActor
    func importFailureSurfacesError() async throws {
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()

        let missing = URL(fileURLWithPath: try makeTempDataDir())
            .appendingPathComponent("does-not-exist.epub").path
        let imported = await model.importEpub(atPath: missing)

        #expect(!imported)
        #expect(model.errorMessage != nil)
        #expect(model.books.isEmpty)

        model.clearError()
        #expect(model.errorMessage == nil)
    }

    @Test("placeholder initials and tint index are deterministic")
    func placeholderVisualsAreDeterministic() {
        #expect(BookCoverPlaceholder.initials(for: "The Brothers Karamazov") == "TB")
        #expect(BookCoverPlaceholder.initials(for: "moby dick") == "MD")
        #expect(BookCoverPlaceholder.initials(for: "Dune") == "D")
        #expect(BookCoverPlaceholder.initials(for: "") == "")

        let paletteSize = 8
        for title in ["Dune", "1984", "A Brief History of Time", "Капитанская дочка", ""] {
            let first = BookCoverPlaceholder.tintIndex(for: title, paletteSize: paletteSize)
            let second = BookCoverPlaceholder.tintIndex(for: title, paletteSize: paletteSize)
            #expect(first == second, "tint must not depend on process state")
            #expect(first >= 0 && first < paletteSize)
        }
    }

    @Test("annotated chapter rows follow the spine and join note stats")
    func annotatedChapterRowsFollowSpineOrder() {
        let chapters = [
            ChapterMeta(key: "001", index: 0, title: "One", href: "one.xhtml", fragment: nil),
            ChapterMeta(key: "002", index: 1, title: "Two", href: "two.xhtml", fragment: nil),
            ChapterMeta(key: "003", index: 2, title: "Three", href: "three.xhtml", fragment: nil),
        ]
        // Index order must not matter: the spine defines the row order.
        let index = [
            NotesIndexEntry(
                chapterKey: "003", file: "chapters/003-three.md", chapterIndex: 2,
                chapterTitle: "Three", wordCount: 41, markCount: 0, updatedAt: nil
            ),
            NotesIndexEntry(
                chapterKey: "001", file: "chapters/001-one.md", chapterIndex: 0,
                chapterTitle: "One", wordCount: 98, markCount: 3,
                updatedAt: Date(timeIntervalSince1970: 1_788_264_000)
            ),
        ]

        let rows = LibraryModel.annotatedChapterRows(chapters: chapters, index: index)

        #expect(rows.map(\.chapter.key) == ["001", "003"])
        #expect(rows[0].wordCount == 98)
        #expect(rows[0].updatedAt == Date(timeIntervalSince1970: 1_788_264_000))
        #expect(rows[1].wordCount == 41)
    }

    @Test("chapter → note word count join from the notes index")
    @MainActor
    func chapterNoteWordCountJoin() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))

        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.noteBody = "one two three four"
        await model.saveChapterNote(reader: reader)
        #expect(reader.notesError == nil)

        // Reloading the book (as the detail view does on selection) brings
        // the notes index along; the join then flags only chapter one.
        await model.loadSelectedBook()
        let counts = LibraryModel.noteWordCounts(
            chapters: book.chapters,
            index: model.selectedBookNotesIndex
        )
        #expect(counts[book.chapters[0].key] == 4)
        #expect(counts.count == 1)
        #expect(counts[book.chapters[1].key] == nil)
    }

    @Test("a pin dropped before relocated picks up the page CFI")
    @MainActor
    func bookmarkDroppedBeforeRelocateGetsCFI() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        let position = try #require(reader.currentPosition())
        #expect(position.epubCfi == nil)
        let pin = try #require(
            await model.addBookmark(bookId: book.id, position: position, reader: reader)
        )
        #expect(pin.epubCfi == nil)
        #expect(reader.pageIsBookmarked)

        reader.relocated(
            page: 1,
            totalPages: 8,
            href: book.chapters[0].href,
            cfi: "epubcfi(/6/4!/4/2)"
        )
        #expect(!reader.pageIsBookmarked)

        await model.stampBookmarkPositions(reader: reader)
        #expect(reader.bookmarks.first?.epubCfi == "epubcfi(/6/4!/4/2)")
        #expect(reader.pageIsBookmarked)
        #expect(model.selectedBookBookmarks.first?.epubCfi == "epubcfi(/6/4!/4/2)")
    }

    @Test("a CFI-less pin written after relocated still picks up the page")
    @MainActor
    func lateCfilessPinPicksUpCurrentPage() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(
            page: 2,
            totalPages: 8,
            href: book.chapters[0].href,
            cfi: "epubcfi(/6/4!/4/2)"
        )
        let stale = ReadingPosition(
            chapterKey: book.chapters[0].key, epubCfi: nil, percent: 0
        )
        _ = try #require(
            await model.addBookmark(bookId: book.id, position: stale, reader: reader)
        )
        #expect(reader.bookmarks.first?.epubCfi == "epubcfi(/6/4!/4/2)")
        #expect(reader.pageIsBookmarked)
    }

    @Test("clearing the selection drops pin glyphs immediately")
    @MainActor
    func clearingSelectionDropsBookmarkGlyphs() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        reader.open(book: book, chapter: book.chapters[0])
        let position = try #require(reader.currentPosition())
        _ = try #require(
            await model.addBookmark(bookId: book.id, position: position, reader: reader)
        )
        #expect(model.selectedBookBookmarks.count == 1)

        await model.selectBook(id: nil)
        #expect(model.selectedBookBookmarks.isEmpty)
    }

    @MainActor
    private func openReader(
        on model: LibraryModel, book: BookMeta
    ) throws -> ReaderModel {
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        reader.relocated(
            page: 2,
            totalPages: 8,
            href: book.chapters[0].href,
            cfi: "epubcfi(/6/4!/4/2/1:0)",
            endPage: 2,
            endHref: book.chapters[0].href,
            endCfi: "epubcfi(/6/4!/4/2/1:99)"
        )
        return reader
    }

    @Test("the bookmark toggle adds and removes the page's pin")
    @MainActor
    func toggleBookmarkRoundTrips() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        let added = await model.toggleBookmark(reader: reader)
        guard case .added(let pin) = added else {
            Issue.record("expected .added, got \(String(describing: added))")
            return
        }
        #expect(pin.epubCfi == "epubcfi(/6/4!/4/2/1:0)")
        #expect(reader.pageIsBookmarked)
        #expect(reader.bookmarks.map(\.id) == [pin.id])
        #expect(model.selectedBookBookmarks.map(\.id) == [pin.id])
        #expect(model.errorMessage == nil)

        let removed = await model.toggleBookmark(reader: reader)
        guard case .removed(let gone) = removed else {
            Issue.record("expected .removed, got \(String(describing: removed))")
            return
        }
        #expect(gone.id == pin.id)
        #expect(reader.bookmarks.isEmpty)
        #expect(!reader.pageIsBookmarked)
        #expect(model.selectedBookBookmarks.isEmpty)
        #expect(!model.bookmarkToggleInFlight)
    }

    @Test("toggling with several pins on the page asks which to remove")
    @MainActor
    func toggleBookmarkOffersChoice() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        let first = try #require(
            await model.addBookmark(
                bookId: book.id,
                position: ReadingPosition(
                    chapterKey: book.chapters[0].key,
                    epubCfi: "epubcfi(/6/4!/4/2/1:0)",
                    percent: 10
                )
            )
        )
        let second = try #require(
            await model.addBookmark(
                bookId: book.id,
                position: ReadingPosition(
                    chapterKey: book.chapters[0].key,
                    epubCfi: "epubcfi(/6/4!/4/2/1:42)",
                    percent: 20
                )
            )
        )

        let result = await model.toggleBookmark(reader: reader)
        guard case .choose(let pins) = result else {
            Issue.record("expected .choose, got \(String(describing: result))")
            return
        }
        #expect(Set(pins.map(\.id)) == [first.id, second.id])
        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.count == 2)
        #expect(reader.bookmarks.count == 2)
        #expect(model.errorMessage == nil)
    }

    @Test("the toggle does nothing until the renderer reports a location")
    @MainActor
    func toggleBookmarkNeedsALocation() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = ReaderModel()
        model.reader = reader
        reader.open(book: book, chapter: book.chapters[0])
        #expect(reader.currentPosition()?.epubCfi == nil)

        let result = await model.toggleBookmark(reader: reader)
        #expect(result == nil)
        #expect(reader.bookmarks.isEmpty)
        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("overlapping toggles collapse to one decision")
    @MainActor
    func overlappingTogglesDoNotDuplicate() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        async let first = model.toggleBookmark(reader: reader)
        async let second = model.toggleBookmark(reader: reader)
        let results = [await first, await second]

        #expect(results.filter { $0 == nil }.count == 1)
        guard let decided = results.compactMap({ $0 }).first, case .added = decided else {
            Issue.record("expected one .added, got \(String(describing: results))")
            return
        }
        #expect(reader.bookmarks.count == 1)
        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.count == 1)
    }

    @Test("a book switch mid-toggle never delivers a stale picker")
    @MainActor
    func staleChoiceIsDiscarded() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        for cfi in ["epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2/1:42)"] {
            _ = try #require(
                await model.addBookmark(
                    bookId: book.id,
                    position: ReadingPosition(
                        chapterKey: book.chapters[0].key,
                        epubCfi: cfi,
                        percent: 10
                    )
                )
            )
        }

        async let result = model.toggleBookmark(reader: reader)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.bookmarkToggleInFlight, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(model.bookmarkToggleInFlight)

        var other = book
        other.id = "other-book"
        reader.open(book: other, chapter: other.chapters[0])

        let outcome = await result
        #expect(outcome == nil)
        #expect(reader.bookmarks.isEmpty)

        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.count == 2)
    }

    @Test("a page turn mid-toggle never delivers a stale picker")
    @MainActor
    func staleChoiceAfterPageTurnIsDiscarded() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        for cfi in ["epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2/1:42)"] {
            _ = try #require(
                await model.addBookmark(
                    bookId: book.id,
                    position: ReadingPosition(
                        chapterKey: book.chapters[0].key,
                        epubCfi: cfi,
                        percent: 10
                    )
                )
            )
        }

        async let result = model.toggleBookmark(reader: reader)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.bookmarkToggleInFlight, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(model.bookmarkToggleInFlight)

        reader.relocated(
            page: 3,
            totalPages: 8,
            href: book.chapters[0].href,
            cfi: "epubcfi(/6/4!/4/2/2:0)",
            endPage: 3,
            endHref: book.chapters[0].href,
            endCfi: "epubcfi(/6/4!/4/2/2:99)"
        )

        let outcome = await result
        #expect(outcome == nil)
        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.count == 2)
    }

    @Test("a reflow that shifts the visible range mid-toggle drops the picker")
    @MainActor
    func staleChoiceAfterRangeShiftIsDiscarded() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        for cfi in ["epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2/1:42)"] {
            _ = try #require(
                await model.addBookmark(
                    bookId: book.id,
                    position: ReadingPosition(
                        chapterKey: book.chapters[0].key,
                        epubCfi: cfi,
                        percent: 10
                    )
                )
            )
        }

        async let result = model.toggleBookmark(reader: reader)
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.bookmarkToggleInFlight, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(model.bookmarkToggleInFlight)

        reader.relocated(
            page: 2,
            totalPages: 6,
            href: book.chapters[0].href,
            cfi: "epubcfi(/6/4!/4/2/1:0)",
            endPage: 3,
            endHref: book.chapters[0].href,
            endCfi: "epubcfi(/6/4!/4/4/2:0)"
        )

        let outcome = await result
        #expect(outcome == nil)
        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.count == 2)
    }

    @Test("a chapter move leaves nothing to pin until the renderer lands")
    @MainActor
    func toggleAfterChapterMoveWaitsForLocation() async throws {
        let fixture = try #require(try fixtureEpubs().first)
        let model = LibraryModel(dataDir: try makeTempDataDir())
        await model.activate()
        #expect(await model.importEpub(atPath: fixture))
        let book = try #require(model.selectedBook)
        let reader = try openReader(on: model, book: book)

        reader.nextChapter()
        #expect(reader.currentPosition()?.epubCfi == nil)
        let blocked = await model.toggleBookmark(reader: reader)
        #expect(blocked == nil)
        #expect(reader.bookmarks.isEmpty)
        let stored = try await model.coreStore!.bookmarks(bookId: book.id)
        #expect(stored.isEmpty)

        reader.relocated(
            page: 1,
            totalPages: 6,
            href: book.chapters[1].href,
            cfi: "epubcfi(/6/6!/4/2/1:0)",
            endPage: 1,
            endHref: book.chapters[1].href,
            endCfi: "epubcfi(/6/6!/4/2/1:9)"
        )
        let added = await model.toggleBookmark(reader: reader)
        guard case .added(let pin) = added else {
            Issue.record("expected .added, got \(String(describing: added))")
            return
        }
        #expect(pin.chapterKey == book.chapters[1].key)
        #expect(pin.epubCfi == "epubcfi(/6/6!/4/2/1:0)")
    }
}
