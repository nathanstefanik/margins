import Foundation
import MarginsCore
import Observation

/// Prose-segment display plumbing. The model shows prose trimmed of its
/// padding newlines; on write-back the segment re-wraps the edited text
/// in its original leading/trailing newline runs, so the byte-exact
/// body concatenation survives edits elsewhere.
public enum NotebookProse {
    /// The segment's text for the editor: raw minus the surrounding
    /// newline runs.
    public static func display(_ raw: String) -> String {
        var text = raw
        while text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Re-wraps edited display text in the raw segment's own leading and
    /// trailing newline runs.
    public static func replacing(_ raw: String, display: String) -> String {
        let leading = raw.prefix(while: { $0 == "\n" })
        let rest = raw.dropFirst(leading.count)
        let trailingStart =
            rest.lastIndex(where: { $0 != "\n" }).map { rest.index(after: $0) }
            ?? rest.endIndex
        return String(leading) + display + String(rest[trailingStart...])
    }
}

/// Owns the notebooks tab and editor: the catalog, the open document
/// (with model-local UUID segment ids — the core's positional ids are
/// never adopted), and debounced autosave. Shares the library's
/// `CoreStore` via `activate(store:)`, like `ClubModel`.
@MainActor
@Observable
public final class NotebookModel {
    public private(set) var notebooks: [NotebookSummary] = []
    /// The open notebook. `segments` carry UUID ids assigned on open.
    public private(set) var current: Notebook?
    public private(set) var errorMessage: String?
    public private(set) var isSaving = false
    /// markId → citing notebooks, for the reader's marks sheet.
    public private(set) var citing: [String: [NotebookSummary]] = [:]

    /// Injectable for tests; production uses the default.
    public var debounceInterval: TimeInterval = 1.0
    /// Suspends for a debounce window. Injectable so tests collapse it —
    /// same pattern as `SearchController.debounceSleep`.
    public var debounceSleep: @Sendable (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(for: .seconds(delay))
    }

    private var store: CoreStore?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    /// Local edits not yet written back. `flush` skips the file write
    /// entirely when clean — reloading `current` after `addPassage` would
    /// otherwise write the stale in-memory segments over the append.
    private var dirty = false

    public init() {}

    /// Shares the library's store and loads the catalog.
    public func activate(store: CoreStore) async {
        self.store = store
        await refresh()
    }

    public func refresh() async {
        guard let store else { return }
        do {
            notebooks = try await store.listNotebooks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func create(title: String) async -> NotebookSummary? {
        guard let store else { return nil }
        do {
            let summary = try await store.createNotebook(title: title)
            errorMessage = nil
            await refresh()
            return summary
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func rename(id: String, title: String) async {
        guard let store else { return }
        do {
            let summary = try await store.renameNotebook(id: id, title: title)
            errorMessage = nil
            if var notebook = current, notebook.summary.id == id {
                notebook.summary = summary
                current = notebook
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(id: String) async {
        guard let store else { return }
        do {
            if current?.summary.id == id {
                saveTask?.cancel()
                saveTask = nil
                dirty = false
                current = nil
            }
            try await store.deleteNotebook(id: id)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the notebook and assigns fresh UUID segment ids — the core's
    /// positional ids would collide on the next edit.
    public func open(id: String) async {
        await flush()
        guard let store else { return }
        do {
            let loaded = try await store.notebook(id: id)
            var notebook = loaded
            notebook.segments = loaded.segments.map {
                NotebookSegment(id: UUID().uuidString, content: $0.content)
            }
            current = notebook
            dirty = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves now if dirty — the debounced save may still hold the same
    /// edits, so cancel it first — then merges the result back
    /// positionally.
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration += 1
        guard dirty, let store, let snapshot = current else { return }
        isSaving = true
        defer { isSaving = false }
        dirty = false
        do {
            let saved = try await store.saveNotebook(
                id: snapshot.summary.id, segments: snapshot.segments)
            applySaved(saved, for: snapshot.summary.id)
            errorMessage = nil
            // Typing during the save left the dirty flag set: reschedule.
            if dirty { scheduleSave() }
            await refresh()
        } catch {
            dirty = true
            errorMessage = error.localizedDescription
        }
    }

    /// Closes the editor, flushing pending edits in the background.
    public func close() {
        let snapshot = dirty ? current : nil
        saveTask?.cancel()
        saveTask = nil
        saveGeneration += 1
        dirty = false
        current = nil
        guard let snapshot, let store else { return }
        isSaving = true
        Task { [weak self] in
            defer { self?.isSaving = false }
            _ = try? await store.saveNotebook(
                id: snapshot.summary.id, segments: snapshot.segments)
            await self?.refresh()
        }
    }

    // MARK: Editing `current`

    /// Replaces a prose segment's display text, re-wrapped in the raw
    /// segment's newline padding. Schedules a debounced save.
    public func updateProse(segmentId: String, display: String) {
        guard var notebook = current,
            let index = notebook.segments.firstIndex(where: { $0.id == segmentId }),
            case .prose(let raw) = notebook.segments[index].content
        else { return }
        notebook.segments[index].content = .prose(NotebookProse.replacing(raw, display: display))
        current = notebook
        dirty = true
        scheduleSave()
    }

    /// Inserts a prose segment after `segmentId` (nil = at the end) and
    /// returns its new id. The raw is "\n\n" so typed text lands on its
    /// own paragraph.
    @discardableResult
    public func insertProse(after segmentId: String?) -> String {
        guard var notebook = current else { return "" }
        let segment = NotebookSegment(id: UUID().uuidString, content: .prose("\n\n"))
        if let segmentId,
            let index = notebook.segments.firstIndex(where: { $0.id == segmentId })
        {
            notebook.segments.insert(segment, at: index + 1)
        } else {
            notebook.segments.append(segment)
        }
        current = Self.normalized(notebook)
        dirty = true
        scheduleSave()
        return segment.id
    }

    /// Moves a passage segment one step (±1) through all segments —
    /// a swap — then normalizes.
    public func movePassage(segmentId: String, by offset: Int) {
        guard var notebook = current,
            let index = notebook.segments.firstIndex(where: { $0.id == segmentId }),
            case .passage = notebook.segments[index].content
        else { return }
        let target = index + offset
        guard notebook.segments.indices.contains(target) else { return }
        notebook.segments.swapAt(index, target)
        current = Self.normalized(notebook)
        dirty = true
        scheduleSave()
    }

    /// Removes any segment by id, then normalizes.
    public func removeSegment(segmentId: String) {
        guard var notebook = current else { return }
        notebook.segments.removeAll { $0.id == segmentId }
        current = Self.normalized(notebook)
        dirty = true
        scheduleSave()
    }

    /// Adds a passage via the core; flushes first when the target is the
    /// open notebook so the append lands on saved bytes. Reloads
    /// `current` when it's the notebook just appended to.
    @discardableResult
    public func addPassage(
        notebookId: String, source: PassageSource, commentary: String
    ) async -> Bool {
        guard let store else { return false }
        if current?.summary.id == notebookId {
            await flush()
        }
        do {
            _ = try await store.addPassage(
                notebookId: notebookId, source: source, commentary: commentary)
            errorMessage = nil
            await refresh()
            if current?.summary.id == notebookId {
                await open(id: notebookId)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Which notebooks cite each mark of the book — the reader's marks
    /// sheet maps by `markId`.
    public func loadCiting(bookId: String) async {
        guard let store else { return }
        citing = (try? await store.notebooksCiting(bookId: bookId)) ?? [:]
    }

    // MARK: Merge / normalize

    /// Merges a save result into `current` positionally (the core's
    /// output is 1:1 with the input order): local ids stay, returned
    /// content lands for passages (fresh raw/cachedQuote/resolution),
    /// prose keeps the local text — the user may have typed while the
    /// save was in flight. A shape mismatch (shouldn't happen) reloads.
    private func applySaved(_ saved: Notebook, for notebookId: String) {
        guard var notebook = current, notebook.summary.id == notebookId else { return }
        guard let merged = Self.merged(local: notebook, saved: saved) else {
            Task { await self.open(id: notebookId) }
            return
        }
        notebook = merged
        current = notebook
    }

    /// The merge itself, exposed for tests: nil when the shapes differ.
    static func merged(local: Notebook, saved: Notebook) -> Notebook? {
        guard local.segments.count == saved.segments.count else { return nil }
        var merged = local
        merged.summary = saved.summary
        for index in local.segments.indices {
            if case .passage = saved.segments[index].content {
                merged.segments[index] = NotebookSegment(
                    id: local.segments[index].id,
                    content: saved.segments[index].content)
            }
        }
        return merged
    }

    /// Runs after structural edits (insert/move/remove — never typing):
    /// prose segments that are exactly "" are dropped, and adjacent
    /// passage segments get a separating prose segment.
    static func normalized(_ notebook: Notebook) -> Notebook {
        var segments = notebook.segments.filter { segment in
            if case .prose(let raw) = segment.content { return !raw.isEmpty }
            return true
        }
        var index = 0
        while index + 1 < segments.count {
            let leftIsPassage: Bool
            let rightIsPassage: Bool
            if case .passage = segments[index].content { leftIsPassage = true }
            else { leftIsPassage = false }
            if case .passage = segments[index + 1].content { rightIsPassage = true }
            else { rightIsPassage = false }
            if leftIsPassage && rightIsPassage {
                segments.insert(
                    NotebookSegment(id: UUID().uuidString, content: .prose("\n")),
                    at: index + 1)
            }
            index += 1
        }
        var normalized = notebook
        normalized.segments = segments
        return normalized
    }

    /// Latest-wins autosave: one debounced save per idle window.
    private func scheduleSave() {
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        let sleep = debounceSleep
        let delay = debounceInterval
        saveTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, self.saveGeneration == generation else { return }
            await self.flush()
        }
    }
}
