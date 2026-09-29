import Foundation
import Testing

@testable import MarginsModel
import MarginsCore

@Suite("Notebook prose helpers")
struct NotebookProseTests {
    @Test("display trims the surrounding newline runs")
    func display() {
        #expect(NotebookProse.display("\n\nhello world\n\n") == "hello world")
        #expect(NotebookProse.display("hello world") == "hello world")
        #expect(NotebookProse.display("\n\n") == "")
        #expect(NotebookProse.display("") == "")
        // Interior newlines are part of the text.
        #expect(NotebookProse.display("\nfirst\n\nsecond\n") == "first\n\nsecond")
    }

    @Test("replacing re-wraps with the raw segment's own padding")
    func replacing() {
        #expect(NotebookProse.replacing("\nold text\n\n", display: "new") == "\nnew\n\n")
        #expect(NotebookProse.replacing("no padding", display: "x") == "x")
        #expect(NotebookProse.replacing("\n\n", display: "typed") == "\n\ntyped")
        #expect(NotebookProse.replacing("", display: "fresh") == "fresh")
    }
}

@Suite("Notebook model")
@MainActor
struct NotebookModelTests {
    /// A CoreStore + its library root on temp dirs.
    private func makeStore() async throws -> (store: CoreStore, root: String) {
        let dataDir = try makeTempDataDir()
        let store = try CoreStore(dataDir: dataDir)
        let root = dataDir + "/library"
        try await store.setLibraryRoot(path: root)
        return (store, root)
    }

    /// A store with the small Wells fixture imported.
    private func makeBookStore() async throws -> (store: CoreStore, book: BookMeta, root: String) {
        let (store, root) = try await makeStore()
        let meta = try await store.importEpub(
            atPath: fixtureEpubs().first(where: { $0.contains("time-machine") })!)
        return (store, meta, root)
    }

    private func makeModel(store: CoreStore) async -> NotebookModel {
        let model = NotebookModel()
        model.debounceSleep = { _ in }  // collapse the debounce window
        await model.activate(store: store)
        return model
    }

    /// The open notebook's file on disk.
    private func notebookFile(_ model: NotebookModel, root: String) throws -> String {
        let file = try #require(model.current?.summary.file)
        return try String(contentsOfFile: "\(root)/notebooks/\(file)", encoding: .utf8)
    }

    @Test("create → listed; open assigns UUID ids, not positional")
    @MainActor
    func createAndOpen() async throws {
        let (store, _) = try await makeStore()
        let model = await makeModel(store: store)

        let summary = try #require(await model.create(title: "Commonplace"))
        #expect(model.notebooks.map(\.id) == [summary.id])
        #expect(model.current == nil)

        await model.open(id: summary.id)
        #expect(model.current?.summary.id == summary.id)
        #expect(model.current?.segments.isEmpty == true)  // fresh body

        // Edit → save → reopen: the persisted positional ids never leak
        // into the model — every segment gets a UUID.
        let inserted = model.insertProse(after: nil)
        model.updateProse(segmentId: inserted, display: "first thought")
        await model.flush()
        await model.open(id: summary.id)
        let segment = try #require(model.current?.segments.first)
        #expect(segment.id.count == 36)  // a UUID, never "s0"
        #expect(segment.id != inserted)  // fresh ids per open
    }

    @Test("updateProse lands on disk after the debounced save")
    @MainActor
    func updateProseSaves() async throws {
        let (store, root) = try await makeStore()
        let model = await makeModel(store: store)
        let summary = try #require(await model.create(title: "Draft"))
        await model.open(id: summary.id)
        let id = model.insertProse(after: nil)

        model.updateProse(segmentId: id, display: "the thought i had")
        // The collapsed sleep means the save fires on the next turn.
        await model.flush()
        #expect(try notebookFile(model, root: root).contains("the thought i had"))
        // Ids survive the save-merge round trip.
        #expect(model.current?.segments.first?.id == id)
    }

    @Test("the save merge keeps local prose text and passage content")
    func mergeKeepsLocalProse() {
        let passage = NotebookPassage(
            ref: PassageRef(bookId: "b", chapterKey: "c", markId: "m"),
            cachedQuote: "q", raw: nil,
            resolution: PassageResolution(status: .ok, quote: "q"))
        let local = Notebook(
            summary: .init(
                id: "n", title: "t", file: "f", passageCount: 1, wordCount: 1,
                createdAt: .now, updatedAt: .now),
            segments: [
                NotebookSegment(id: "u1", content: .prose("typed while saving")),
                NotebookSegment(id: "u2", content: .passage(passage)),
            ])
        var saved = local
        saved.segments = [
            NotebookSegment(id: "s0", content: .prose("older saved text")),
            NotebookSegment(id: "s1", content: .passage(passage)),
        ]
        let merged = try! #require(NotebookModel.merged(local: local, saved: saved))
        // Prose keeps the LOCAL text (the user typed during the save);
        // passages adopt the returned content but keep the local id.
        #expect(merged.segments[0].content == .prose("typed while saving"))
        #expect(merged.segments[0].id == "u1")
        #expect(merged.segments[1].id == "u2")
        #expect(merged.segments[1].content == .passage(passage))
        // Shape mismatch → nil (the model reloads).
        var off = local
        off.segments.removeLast()
        #expect(NotebookModel.merged(local: off, saved: saved) == nil)
    }

    @Test("normalization drops empty prose and separates adjacent passages")
    func normalize() {
        let passage = NotebookPassage(
            ref: PassageRef(bookId: "b", chapterKey: "c", markId: "m"),
            cachedQuote: "q", raw: nil,
            resolution: PassageResolution(status: .ok, quote: "q"))
        var notebook = Notebook(
            summary: .init(
                id: "n", title: "t", file: "f", passageCount: 0, wordCount: 0,
                createdAt: .now, updatedAt: .now),
            segments: [
                NotebookSegment(id: "a", content: .prose("")),
                NotebookSegment(id: "b", content: .passage(passage)),
                NotebookSegment(id: "c", content: .passage(passage)),
                NotebookSegment(id: "d", content: .prose("tail")),
            ])
        notebook = NotebookModel.normalized(notebook)
        // Empty prose dropped; a "\n" prose wedged between the passages.
        #expect(notebook.segments.count == 4)
        #expect(notebook.segments[0].id == "b")
        if case .prose(let raw) = notebook.segments[1].content {
            #expect(raw == "\n")
        } else {
            Issue.record("expected separator prose")
        }
        #expect(notebook.segments[2].id == "c")
        #expect(notebook.segments[3].content == .prose("tail"))
    }

    @Test("insert/move/remove edit the open notebook and normalize")
    @MainActor
    func structuralEdits() async throws {
        let (store, book, _) = try await makeBookStore()
        let model = await makeModel(store: store)
        let summary = try #require(await model.create(title: "Moves"))
        await model.open(id: summary.id)

        // Seed one passage via the core so the notebook has a card.
        let added = await model.addPassage(
            notebookId: summary.id,
            source: .selection(
                bookId: book.id, chapterKey: book.chapters[0].key,
                cfi: nil, percent: nil, quote: "a quoted line"),
            commentary: "")
        #expect(added)
        // The empty commentary seeds `[passage]` alone — insert prose
        // after it, then move the passage over it and back.
        let passageIndex = model.current!.segments
            .firstIndex {
                if case .passage = $0.content { return true }
                return false
            }
        let passageId = model.current!.segments[try #require(passageIndex)].id
        let count = model.current!.segments.count

        let proseId = model.insertProse(after: passageId)
        #expect(model.current!.segments.count == count + 1)
        #expect(model.current!.segments[passageIndex! + 1].id == proseId)

        model.movePassage(segmentId: passageId, by: 1)
        #expect(model.current!.segments.firstIndex { $0.id == passageId } == passageIndex! + 1)
        model.movePassage(segmentId: passageId, by: -1)
        #expect(model.current!.segments.firstIndex { $0.id == passageId } == passageIndex)

        model.removeSegment(segmentId: proseId)
        #expect(model.current!.segments.count == count)

        await model.flush()
        #expect(model.errorMessage == nil)
    }

    @Test("addPassage(.selection) creates the mark and reloads current")
    @MainActor
    func addPassageSelection() async throws {
        let (store, book, _) = try await makeBookStore()
        let model = await makeModel(store: store)
        let summary = try #require(await model.create(title: "Reading"))
        await model.open(id: summary.id)

        let added = await model.addPassage(
            notebookId: summary.id,
            source: .selection(
                bookId: book.id, chapterKey: book.chapters[0].key,
                cfi: nil, percent: nil, quote: "a peculiar machine"),
            commentary: "my note on it")
        #expect(added)

        // The notebook reloaded with a passage segment whose resolution
        // found the freshly created mark.
        let passage = model.current!.segments.first {
            if case .passage = $0.content { return true }
            return false
        }
        guard case .passage(let card) = try #require(passage?.content) else { return }
        #expect(card.resolution.status == .ok)
        // The mark exists in the chapter note.
        let note = try await store.getChapterNote(
            bookId: book.id, chapterKey: book.chapters[0].key)
        #expect(note.marks.contains { $0.id == card.ref.markId })

        // Reverse lookup sees the citation.
        await model.loadCiting(bookId: book.id)
        #expect(model.citing[card.ref.markId]?.contains { $0.id == summary.id } == true)
    }

    @Test("delete removes the notebook and closes it when open")
    @MainActor
    func deleteNotebook() async throws {
        let (store, _) = try await makeStore()
        let model = await makeModel(store: store)
        let summary = try #require(await model.create(title: "Gone"))
        await model.open(id: summary.id)
        await model.delete(id: summary.id)
        #expect(model.current == nil)
        #expect(model.notebooks.isEmpty)
    }
}
