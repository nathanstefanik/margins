import MarginsCore
import MarginsModel
import SwiftUI

/// The Notebooks tab: a list of commonplace notebooks over a
/// `NavigationStack` whose pushed values are notebook ids.
struct NotebooksScene: View {
    @Environment(NotebookModel.self) private var notebooks

    @Binding var path: [String]

    @State private var createAlert = false
    @State private var createTitle = ""
    @State private var renaming: NotebookSummary?
    @State private var renameTitle = ""
    @State private var deleting: NotebookSummary?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Notebooks")
                .navigationDestination(for: String.self) { notebookId in
                    NotebookDetailView(notebookId: notebookId)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            createTitle = ""
                            createAlert = true
                        } label: {
                            Label("New Notebook", systemImage: "plus")
                        }
                    }
                }
                .alert("New Notebook", isPresented: $createAlert) {
                    TextField("Title", text: $createTitle)
                    Button("Create") { create(createTitle) }
                    Button("Cancel", role: .cancel) {}
                }
                .alert(
                    "Rename Notebook",
                    isPresented: Binding(
                        get: { renaming != nil },
                        set: { if !$0 { renaming = nil } }
                    )
                ) {
                    TextField("Title", text: $renameTitle)
                    Button("Rename") {
                        if let notebook = renaming {
                            Task { await notebooks.rename(id: notebook.id, title: renameTitle) }
                        }
                        renaming = nil
                    }
                    Button("Cancel", role: .cancel) { renaming = nil }
                }
                .confirmationDialog(
                    "Delete Notebook?",
                    isPresented: Binding(
                        get: { deleting != nil },
                        set: { if !$0 { deleting = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        guard let notebook = deleting else { return }
                        deleting = nil
                        Task { await notebooks.delete(id: notebook.id) }
                    }
                    Button("Cancel", role: .cancel) { deleting = nil }
                } message: {
                    Text(
                        "Delete “\(deleting?.title ?? "")”? Its passages stay marked in their books."
                    )
                }
        }
        .task { await notebooks.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if notebooks.notebooks.isEmpty {
            ContentUnavailableView {
                Label("No notebooks yet", systemImage: "text.book.closed")
            } description: {
                Text("Gather passages from any book with your own thoughts between them.")
            } actions: {
                Button("New Notebook") {
                    createTitle = ""
                    createAlert = true
                }
            }
        } else {
            List {
                ForEach(notebooks.notebooks) { notebook in
                    Button {
                        path.append(notebook.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notebook.title)
                                    .font(.headline)
                                Text(subtitle(for: notebook))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if notebook.isEvicted {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Not downloaded")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button {
                            renameTitle = notebook.title
                            renaming = notebook
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleting = notebook
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for notebook: NotebookSummary) -> String {
        let passages =
            notebook.passageCount == 1 ? "1 passage" : "\(notebook.passageCount) passages"
        let edited = notebook.updatedAt.formatted(.relative(presentation: .named))
        return "\(passages) · edited \(edited)"
    }

    private func create(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            if let summary = await notebooks.create(title: trimmed) {
                path.append(summary.id)
            }
        }
    }
}

/// One open notebook: prose segments edit in place (debounced autosave
/// inside `NotebookModel`), passage cards jump back to their source, and
/// the toolbar picks a new passage from library search.
struct NotebookDetailView: View {
    @Environment(NotebookModel.self) private var notebooks
    @Environment(\.openPassage) private var openPassage
    @Environment(\.scenePhase) private var scenePhase

    let notebookId: String

    @FocusState private var focusedSegment: String?
    /// The picker's own search — sharing `app.search` would leak state
    /// between the sheet and the Search tab.
    @State private var pickerSearch = LibrarySearch()
    @State private var pickerPresented = false
    @State private var renameAlert = false
    @State private var renameTitle = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let current = notebooks.current, current.summary.id == notebookId {
                    ForEach(current.segments) { segment in
                        switch segment.content {
                        case .prose:
                            proseEditor(segment: segment)
                        case .passage(let passage):
                            passageCard(passage, segmentId: segment.id)
                        }
                    }
                    addThoughtButton
                }
            }
            .padding()
        }
        .navigationTitle(
            notebooks.current?.summary.id == notebookId
                ? (notebooks.current?.summary.title ?? "")
                : ""
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pickerPresented = true
                } label: {
                    Label("Add Passage", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Rename…") {
                    renameTitle = notebooks.current?.summary.title ?? ""
                    renameAlert = true
                }
            }
            if notebooks.isSaving {
                ToolbarItem(placement: .secondaryAction) {
                    ProgressView()
                        .accessibilityLabel("Saving notebook")
                }
            }
        }
        .sheet(isPresented: $pickerPresented) {
            NavigationStack {
                LibrarySearchView(search: pickerSearch, mode: .picker(notebookId: notebookId))
            }
            .presentationDetents([.large])
        }
        .alert("Rename Notebook", isPresented: $renameAlert) {
            TextField("Title", text: $renameTitle)
            Button("Rename") {
                Task { await notebooks.rename(id: notebookId, title: renameTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await notebooks.open(id: notebookId)
            // A fresh notebook starts with one focused prose field.
            if notebooks.current?.segments.isEmpty == true {
                focusedSegment = notebooks.insertProse(after: nil)
            }
        }
        .onDisappear {
            Task { await notebooks.flush() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await notebooks.flush() }
            }
        }
    }

    // MARK: Segments

    private func proseEditor(segment: NotebookSegment) -> some View {
        TextField(
            "Write…",
            text: Binding(
                get: {
                    guard
                        case .prose(let raw) = notebooks.current?.segments
                            .first(where: { $0.id == segment.id })?.content
                    else { return "" }
                    return NotebookProse.display(raw)
                },
                set: { notebooks.updateProse(segmentId: segment.id, display: $0) }
            ),
            axis: .vertical
        )
        .font(.body)
        .textFieldStyle(.plain)
        .focused($focusedSegment, equals: segment.id)
    }

    private var addThoughtButton: some View {
        Button {
            focusedSegment = notebooks.insertProse(after: nil)
        } label: {
            Label("Add a thought", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.bordered)
    }

    /// A passage card: serif quote over an "Author · Title · Chapter"
    /// citation, with a status footnote when the source can't resolve.
    /// Plain secondary background — a card is content, not a control.
    private func passageCard(_ passage: NotebookPassage, segmentId: String) -> some View {
        let resolution = passage.resolution
        let missing = resolution.status == .bookMissing
        return Button {
            openPassage(
                PassageTarget(
                    bookId: passage.ref.bookId,
                    chapterKey: passage.ref.chapterKey,
                    cfi: resolution.cfi,
                    revealText: (resolution.cfi?.isEmpty ?? true) ? resolution.quote : nil,
                    markId: passage.ref.markId))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(resolution.quote.isEmpty ? passage.cachedQuote : resolution.quote)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.primary)
                Text(
                    [
                        resolution.bookAuthor, resolution.bookTitle, resolution.chapterTitle,
                    ]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if resolution.status != .ok {
                    Text(statusNote(for: resolution.status))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                .secondary.opacity(0.12),
                in: .rect(cornerRadius: DesignTokens.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(missing)
        .contextMenu {
            Button {
                notebooks.movePassage(segmentId: segmentId, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            Button {
                notebooks.movePassage(segmentId: segmentId, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            Button {
                focusedSegment = notebooks.insertProse(after: segmentId)
            } label: {
                Label("Add Note Below", systemImage: "text.badge.plus")
            }
            Divider()
            Button(role: .destructive) {
                notebooks.removeSegment(segmentId: segmentId)
            } label: {
                Label("Remove from Notebook", systemImage: "trash")
            }
        }
        .accessibilityLabel("Passage from \(resolution.bookTitle ?? "book"): \(resolution.quote)")
        .accessibilityAction(named: "Move Up") {
            notebooks.movePassage(segmentId: segmentId, by: -1)
        }
        .accessibilityAction(named: "Move Down") {
            notebooks.movePassage(segmentId: segmentId, by: 1)
        }
        .accessibilityAction(named: "Add Note Below") {
            focusedSegment = notebooks.insertProse(after: segmentId)
        }
        .accessibilityAction(named: "Remove from Notebook") {
            notebooks.removeSegment(segmentId: segmentId)
        }
    }

    private func statusNote(for status: PassageStatus) -> String {
        switch status {
        case .ok: ""
        case .markMissing: "Source removed"
        case .bookMissing: "Book removed"
        case .notDownloaded: "Not downloaded"
        }
    }
}
