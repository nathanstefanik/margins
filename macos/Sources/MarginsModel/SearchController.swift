import Foundation
import Observation
import MarginsCore

/// Seam for the search backend so tests can spy on executions.
public protocol SearchStore: Sendable {
    func searchNotes(query: String) async throws -> [NoteSearchHit]
}

extension CoreStore: SearchStore {}

/// Owns the palette's query lifecycle: ~150 ms debounce, latest-wins
/// execution (stale results are discarded, never applied), capped results
/// with a truncation flag, and recent-search persistence in UserDefaults —
/// chrome state, not library data.
@MainActor
@Observable
public final class SearchController {
    public static let resultCap = 50
    public static let recentsCap = 5
    static let defaultDebounceInterval: TimeInterval = 0.15
    private static let recentsKey = "search.recentQueries"

    /// Injectable for tests; production uses the default.
    public var debounceInterval: TimeInterval = SearchController.defaultDebounceInterval

    public private(set) var query = ""
    public private(set) var results: [NoteSearchHit] = []
    /// True when the backend found more matches than `resultCap`.
    public private(set) var isTruncated = false
    public private(set) var isSearching = false
    public private(set) var recents: [String] = []

    private var task: Task<Void, Never>?
    private var generation = 0
    private var executor: (@Sendable (String) async -> [NoteSearchHit])?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recents = defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Wiring point for the actual backend (the library's store).
    public func setExecutor(_ executor: (@Sendable (String) async -> [NoteSearchHit])?) {
        self.executor = executor
    }

    /// Every keystroke lands here; schedules one debounced search. Results
    /// from superseded queries are dropped, never applied.
    public func setQuery(_ text: String) {
        query = text
        task?.cancel()
        generation += 1

        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            isTruncated = false
            isSearching = false
            return
        }
        isSearching = true

        let myGeneration = generation
        let delay = debounceInterval
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == myGeneration else { return }
            let searched = self.query
            let hits = await self.execute(searched)
            guard !Task.isCancelled, self.generation == myGeneration else { return }
            self.apply(hits, for: searched)
        }
    }

    /// Re-runs a recent search (Enter on a recents row) and moves it to the
    /// front of the list.
    public func runRecent(_ text: String) {
        setQuery(text)
        commitRecent(text)
    }

    /// Records a submitted query: opening a hit, or re-running a recent.
    public func commitRecent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recents.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recents.insert(trimmed, at: 0)
        if recents.count > Self.recentsCap {
            recents.removeLast(recents.count - Self.recentsCap)
        }
        defaults.set(recents, forKey: Self.recentsKey)
    }

    /// Clears transient state when the palette closes; recents persist.
    public func reset() {
        task?.cancel()
        task = nil
        generation += 1
        query = ""
        results = []
        isTruncated = false
        isSearching = false
    }

    private func execute(_ text: String) async -> [NoteSearchHit] {
        guard let executor else { return [] }
        return await executor(text)
    }

    private func apply(_ hits: [NoteSearchHit], for text: String) {
        guard text == query, generation > 0 else { return }
        results = Array(hits.prefix(Self.resultCap))
        isTruncated = hits.count > Self.resultCap
        isSearching = false
    }
}
