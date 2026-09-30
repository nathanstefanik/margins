import Foundation
import MarginsCore
import Observation

/// One row in the grouped library-search results — either a captured
/// (notes/marks/notebooks) hit or a full-text hit.
public enum LibrarySearchItem: Identifiable, Hashable, Sendable {
    case captured(NoteSearchHit)
    case text(TextSearchHit)

    public var id: String {
        switch self {
        case .captured(let hit): "captured:\(hit.id)"
        case .text(let hit): "text:\(hit.id)"
        }
    }
}

/// A titled group in the fixed display order (see
/// `LibrarySearch.sections`); empty groups are never produced.
public struct LibrarySearchSection: Equatable, Sendable {
    public var title: String
    public var items: [LibrarySearchItem]

    public init(title: String, items: [LibrarySearchItem]) {
        self.title = title
        self.items = items
    }
}

/// The shared library-search model — the Search tab, the reader's
/// "Search Library", and the "Add to Notebook" picker drive the same
/// queries: captured search over notes/marks/notebooks plus the
/// per-device full-text index. 250 ms debounce, latest-wins results.
@MainActor
@Observable
public final class LibrarySearch {
    public static let fullTextLimit = 50
    static let defaultDebounceInterval: TimeInterval = 0.25

    public private(set) var query = ""
    public private(set) var captured: [NoteSearchHit] = []
    public private(set) var fullText: [TextSearchHit] = []
    public private(set) var isSearching = false

    /// The app's indexing pass publishes these; nil = nothing running.
    public var indexStatus: TextIndexStatus?
    public var indexingProgress: (done: Int, total: Int)?

    /// Injectable for tests; production uses the default.
    public var debounceInterval: TimeInterval = LibrarySearch.defaultDebounceInterval
    /// Suspends for a debounce window. Injectable so tests collapse it —
    /// same pattern as `SearchController.debounceSleep`.
    public var debounceSleep: @Sendable (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(for: .seconds(delay))
    }

    /// The backends. Tests inject spies; `attach` wires a CoreStore.
    public var capturedExecutor: @Sendable (String) async throws -> [NoteSearchHit] = { _ in [] }
    public var fullTextExecutor: @Sendable (String) async throws -> [TextSearchHit] = { _ in [] }

    private var task: Task<Void, Never>?
    private var generation = 0

    public init() {}

    /// Wiring point: the app attaches its store once at activation.
    public func attach(store: CoreStore) {
        capturedExecutor = { try await store.searchNotes(query: $0) }
        fullTextExecutor = { try await store.searchBookText(query: $0, limit: Self.fullTextLimit) }
    }

    /// Every keystroke lands here; schedules one debounced run of both
    /// searches. Results from superseded queries are dropped, never
    /// applied.
    public func setQuery(_ text: String) {
        query = text
        task?.cancel()
        generation += 1

        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            captured = []
            fullText = []
            isSearching = false
            return
        }
        isSearching = true

        let myGeneration = generation
        let sleep = debounceSleep
        let delay = debounceInterval
        task = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, self.generation == myGeneration else { return }
            let capturedHits = (try? await self.capturedExecutor(text)) ?? []
            let textHits = (try? await self.fullTextExecutor(text)) ?? []
            guard !Task.isCancelled, self.generation == myGeneration else { return }
            self.captured = capturedHits
            self.fullText = textHits
            self.isSearching = false
        }
    }

    /// Clears the query and results (sheet dismissed).
    public func reset() {
        task?.cancel()
        task = nil
        generation += 1
        query = ""
        captured = []
        fullText = []
        isSearching = false
    }

    // MARK: Grouping (pure)

    /// The display order: Passages (marks), In Your Books (full text),
    /// Notebooks, Notes, Chapters & Books. Empty sections are omitted.
    public static func sections(
        captured: [NoteSearchHit], fullText: [TextSearchHit]
    ) -> [LibrarySearchSection] {
        var sections: [LibrarySearchSection] = []
        let marks = captured.filter { $0.kind == .mark }
        if !marks.isEmpty {
            sections.append(
                LibrarySearchSection(title: "Passages", items: marks.map { .captured($0) }))
        }
        if !fullText.isEmpty {
            sections.append(
                LibrarySearchSection(title: "In Your Books", items: fullText.map { .text($0) }))
        }
        let notebooks = captured.filter { $0.kind == .notebook }
        if !notebooks.isEmpty {
            sections.append(
                LibrarySearchSection(title: "Notebooks", items: notebooks.map { .captured($0) }))
        }
        let notes = captured.filter { $0.kind == .noteContent }
        if !notes.isEmpty {
            sections.append(
                LibrarySearchSection(title: "Notes", items: notes.map { .captured($0) }))
        }
        let navigation = captured.filter {
            $0.kind == .chapterTitle || $0.kind == .bookTarget
        }
        if !navigation.isEmpty {
            sections.append(
                LibrarySearchSection(title: "Chapters & Books", items: navigation.map { .captured($0) }))
        }
        return sections
    }

    /// How a passage-like result enters a notebook: mark hits point at
    /// the mark; full-text hits become selections whose quote the core
    /// reuses-or-creates a mark for. Other kinds can't be added.
    public static func passageSource(for item: LibrarySearchItem) -> PassageSource? {
        switch item {
        case .captured(let hit):
            guard hit.kind == .mark, let markId = hit.markId else { return nil }
            return .mark(bookId: hit.bookId, chapterKey: hit.chapterKey, markId: markId)
        case .text(let hit):
            return .selection(
                bookId: hit.bookId, chapterKey: hit.chapterKey,
                cfi: nil, percent: nil, quote: hit.passage)
        }
    }
}
