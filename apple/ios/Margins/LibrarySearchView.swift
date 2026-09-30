import MarginsCore
import MarginsModel
import SwiftUI

/// The one library search surface: the Search tab (`browse`) and the
/// Add-Passage picker (`picker`) share rows, ordering, and highlighting.
/// Owns no model itself — the app injects `app.search`, sheets create
/// their own `LibrarySearch` so query state isn't shared; the index
/// banner always reads the app-wide pass on `app.search`.
struct LibrarySearchView: View {
    enum Mode {
        /// The Search tab: every section, passage-like rows offer
        /// "Add to Notebook…".
        case browse
        /// Picking a passage for `notebookId`: only Passages + In Your
        /// Books, a tap adds straight away.
        case picker(notebookId: String)
    }

    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library
    @Environment(NotebookModel.self) private var notebooks
    @Environment(\.openPassage) private var openPassage
    @Environment(\.openNotebook) private var openNotebook
    @Environment(\.dismiss) private var dismiss

    let search: LibrarySearch
    let mode: Mode

    /// A passage marked for the notebook sheet (browse mode).
    @State private var pendingAdd: AddCandidate?

    /// A passage-like result awaiting a target notebook.
    private struct AddCandidate: Identifiable {
        let id = UUID()
        let source: PassageSource
        let preview: String
    }

    private var queryBinding: Binding<String> {
        Binding(get: { search.query }, set: { search.setQuery($0) })
    }

    private var sections: [LibrarySearchSection] {
        let all = LibrarySearch.sections(captured: search.captured, fullText: search.fullText)
        switch mode {
        case .browse:
            return all
        case .picker:
            return all.filter { $0.title == "Passages" || $0.title == "In Your Books" }
        }
    }

    var body: some View {
        content
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                prompt: "Search passages, notes, and books"
            )
            .sheet(item: $pendingAdd) { candidate in
                AddToNotebookSheet(source: candidate.source, preview: candidate.preview) { _ in }
            }
            .task {
                // Sheets own their model; attaching is idempotent so the
                // app-owned instance just rebinds the same store.
                if let store = library.coreStore {
                    search.attach(store: store)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 0) {
                indexBanner
                ContentUnavailableView {
                    Label("Search your library", systemImage: "magnifyingglass")
                } description: {
                    Text(
                        "Find passages, notes, and lines in every book — even from a few remembered words."
                    )
                }
            }
        } else {
            List {
                indexBanner
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            row(for: item)
                        }
                    }
                }
            }
        }
    }

    /// The index banner rides at the top of the results (or over the
    /// empty state): progress while a pass runs, else the count of books
    /// whose text cannot be searched.
    @ViewBuilder
    private var indexBanner: some View {
        if let progress = app.search.indexingProgress {
            Label(
                "Indexing books… \(progress.done) of \(progress.total)",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let status = app.search.indexStatus, !status.pendingBookIds.isEmpty {
            let n = status.pendingBookIds.count
            Label(
                "\(n) \(n == 1 ? "book" : "books") \(n == 1 ? "isn't" : "aren't") downloaded — \(n == 1 ? "its" : "their") text isn't searchable yet.",
                systemImage: "icloud.and.arrow.down"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for item: LibrarySearchItem) -> some View {
        switch item {
        case .captured(let hit):
            capturedRow(hit)
        case .text(let hit):
            textRow(hit)
        }
    }

    private var highlight: AttributeContainer {
        AttributeContainer().font(.body.weight(.semibold))
    }

    @ViewBuilder
    private func capturedRow(_ hit: NoteSearchHit) -> some View {
        switch hit.kind {
        case .mark:
            passageRow(
                snippet: hit.snippet, ranges: hit.snippetRanges,
                caption: "\(hit.bookTitle) · \(hit.chapterTitle)",
                action: {
                    openPassage(
                        PassageTarget(
                            bookId: hit.bookId, chapterKey: hit.chapterKey,
                            cfi: hit.cfi, markId: hit.markId))
                },
                item: .captured(hit))
        case .notebook:
            Button {
                if let notebookId = hit.notebookId {
                    openNotebook(notebookId)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.chapterTitle.isEmpty ? hit.snippet : hit.chapterTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(hit.snippet)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.primary)
        case .noteContent, .chapterTitle, .bookTarget:
            Button {
                openPassage(
                    PassageTarget(
                        bookId: hit.bookId, chapterKey: hit.chapterKey, cfi: hit.cfi))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        SearchHighlighter.attributed(
                            hit.chapterTitle.isEmpty ? hit.bookTitle : hit.chapterTitle,
                            ranges: hit.titleRanges, highlight: highlight)
                    )
                    .font(.headline)
                    .foregroundStyle(.primary)
                    Text(
                        SearchHighlighter.attributed(
                            hit.snippet, ranges: hit.snippetRanges, highlight: highlight)
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func textRow(_ hit: TextSearchHit) -> some View {
        passageRow(
            snippet: hit.snippet, ranges: hit.snippetRanges,
            caption: "\(hit.bookTitle) · \(hit.chapterTitle)",
            action: {
                // No CFI — the reveal locates the passage text on the page.
                openPassage(
                    PassageTarget(
                        bookId: hit.bookId, chapterKey: hit.chapterKey,
                        revealText: hit.passage))
            },
            item: .text(hit))
    }

    /// The shared card for passage-like results (marks and full-text
    /// hits): serif highlighted snippet over a "Book · Chapter" caption.
    /// In browse mode the row opens the passage and offers
    /// "Add to Notebook…"; in picker mode a tap adds it immediately.
    private func passageRow(
        snippet: String, ranges: [MatchRange], caption: String,
        action: @escaping () -> Void, item: LibrarySearchItem
    ) -> some View {
        Button {
            switch mode {
            case .browse:
                action()
            case .picker(let notebookId):
                addToNotebook(notebookId: notebookId, item: item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    SearchHighlighter.attributed(snippet, ranges: ranges, highlight: highlight)
                )
                .font(.system(.callout, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(3)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.primary)
        .modifier(
            AddToNotebookSwipe(item: item) { source in
                pendingAdd = AddCandidate(source: source, preview: snippet)
            })
    }

    private func addToNotebook(notebookId: String, item: LibrarySearchItem) {
        guard let source = LibrarySearch.passageSource(for: item) else { return }
        Task {
            if await notebooks.addPassage(
                notebookId: notebookId, source: source, commentary: "")
            {
                dismiss()
            }
        }
    }
}

/// Swipe + context-menu "Add to Notebook…" on rows that map to a
/// `PassageSource` — a no-op modifier for everything else.
private struct AddToNotebookSwipe: ViewModifier {
    let item: LibrarySearchItem
    let onAdd: (PassageSource) -> Void

    init(item: LibrarySearchItem, onAdd: @escaping (PassageSource) -> Void) {
        self.item = item
        self.onAdd = onAdd
    }

    func body(content: Content) -> some View {
        if let source = LibrarySearch.passageSource(for: item) {
            content
                .swipeActions {
                    Button {
                        onAdd(source)
                    } label: {
                        Label("Add to Notebook…", systemImage: "text.book.closed")
                    }
                    .tint(.accentColor)
                }
                .contextMenu {
                    Button {
                        onAdd(source)
                    } label: {
                        Label("Add to Notebook…", systemImage: "text.book.closed")
                    }
                }
        } else {
            content
        }
    }
}
