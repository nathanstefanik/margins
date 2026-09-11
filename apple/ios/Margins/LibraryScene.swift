import SwiftUI
import UniformTypeIdentifiers
import MarginsCore
import MarginsModel

/// The app's tab anatomy: **Library** and **Search**, one information
/// architecture that adapts from a compact floating tab bar to a regular
/// sidebar (`.sidebarAdaptable`) instead of a hand-built per-device layout.
/// Global notes search owns its own tab — its scope is the whole library —
/// while contextual search belongs over the content it filters.
enum AppTab: Hashable {
    case library
    case search
}

/// A book pushed onto the Library tab's navigation stack.
enum LibraryRoute: Hashable {
    case book(id: String)
}

struct LibraryScene: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppModel.self) private var app

    @State private var selectedTab: AppTab = .library
    @State private var libraryPath: [LibraryRoute] = []
    @State private var query = ""
    @State private var hits: [NoteSearchHit] = []
    @State private var importPresented = false
    @State private var bookPendingDeletion: BookSummary?
    @State private var readerActive = false

    /// Shared by the grid covers and the reader so the reader grows out of
    /// the cover that was tapped.
    @Namespace private var zoomNamespace

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                libraryTab
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                searchTab
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay { materializingOverlay }
        #if DEBUG
        .task { await runDebugSeams() }
        #endif
    }

    // MARK: Library tab

    private var libraryTab: some View {
        NavigationStack(path: $libraryPath) {
            libraryContent
                .navigationTitle("Margins")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            importPresented = true
                        } label: {
                            Label("Import EPUB", systemImage: "plus")
                        }
                        .help("Import an EPUB from Files")
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { _ in
                    BookDetailView(readerActive: $readerActive)
                        .navigationDestination(isPresented: $readerActive) {
                            ReaderScene(zoomNamespace: zoomNamespace)
                        }
                }
                .fileImporter(
                    isPresented: $importPresented,
                    allowedContentTypes: [.epub, .data],
                    allowsMultipleSelection: false
                ) { result in
                    handleImportResult(result)
                }
                .confirmationDialog(
                    "Delete Book?",
                    isPresented: Binding(
                        get: { bookPendingDeletion != nil },
                        set: { if !$0 { bookPendingDeletion = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Book", role: .destructive) {
                        guard let book = bookPendingDeletion else { return }
                        bookPendingDeletion = nil
                        Task { await library.removeBook(id: book.id) }
                    }
                    Button("Cancel", role: .cancel) {
                        bookPendingDeletion = nil
                    }
                } message: {
                    Text("Remove \"\(bookPendingDeletion?.title ?? "")\" and its notes from the library? The original EPUB file is untouched.")
                }
                .alert(
                    "Something went wrong",
                    isPresented: Binding(
                        get: { library.errorMessage != nil },
                        set: { if !$0 { library.errorMessage = nil } }
                    )
                ) {
                    Button("OK") {}
                } message: {
                    Text(library.errorMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if library.books.isEmpty {
            ContentUnavailableView {
                Label("No books yet", systemImage: "book")
            } description: {
                Text("Import an EPUB to start reading and taking notes.")
            } actions: {
                Button("Import EPUB") {
                    importPresented = true
                }
            }
        } else {
            ScrollView {
                if let status = library.importStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                if let notice = app.locationNotice {
                    Label(notice, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: DesignTokens.Spacing.gridCell)],
                    spacing: DesignTokens.Spacing.grid
                ) {
                    ForEach(library.books) { book in
                        Button {
                            select(book.id)
                        } label: {
                            BookGridCell(book: book, zoomNamespace: zoomNamespace)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                bookPendingDeletion = book
                            } label: {
                                Label("Delete…", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func select(_ id: String) {
        Task {
            await library.selectBook(id: id)
            libraryPath.append(.book(id: id))
        }
    }

    // MARK: Search tab

    private var searchTab: some View {
        NavigationStack {
            searchResults
                .navigationTitle("Search")
                .searchable(text: $query, prompt: "Search notes")
                .task(id: query) {
                    await runSearch()
                }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            ContentUnavailableView {
                Label("Search your notes", systemImage: "magnifyingglass")
            } description: {
                Text("Find a phrase across every book's annotations.")
            }
        } else if hits.isEmpty {
            ContentUnavailableView.search
        } else {
            List {
                ForEach(hits) { hit in
                    Button {
                        openFromSearch(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.chapterTitle)
                                .font(.headline)
                            Text("\(hit.bookTitle) · \(hit.snippet)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    /// A hit opens the reader inside the Library tab; switching tabs and
    /// rebuilding the path keeps the reader in the same navigation tree the
    /// grid owns rather than a detached one.
    private func openFromSearch(_ hit: NoteSearchHit) {
        Task {
            guard await app.prepareForReading(bookId: hit.bookId) else { return }
            await library.openPassage(bookId: hit.bookId, chapterKey: hit.chapterKey, cfi: nil)
            selectedTab = .library
            libraryPath = [.book(id: hit.bookId)]
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hits = []
            return
        }
        // Debounce: the searchable field fires on every keystroke.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        hits = await library.searchNotes(trimmed)
    }

    // MARK: Overlays

    @ViewBuilder
    private var materializingOverlay: some View {
        if app.isMaterializing {
            ZStack {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView("Downloading book…")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading book from iCloud")
        }
    }

    // MARK: Import

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            library.errorMessage = String(describing: error)
        case .success(let urls):
            guard let picked = urls.first else { return }
            Task { await app.importSecurityScoped(picked) }
        }
    }

    #if DEBUG
    /// Development seams for simulator verification: import a fixture,
    /// prefill search, preselect a book, or drive the delete flow without
    /// touch synthesis. Sequential so the fixture does not race activation.
    private func runDebugSeams() async {
        await app.activate()
        await importFixtureIfRequested()
        if let search = ProcessInfo.processInfo.environment["MARGINS_SEARCH_FIXTURE"] {
            for _ in 0..<50 where library.books.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            selectedTab = .search
            query = search
        }
        if ProcessInfo.processInfo.environment["MARGINS_OPEN_FIXTURE"] != nil {
            for _ in 0..<50 where library.books.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let first = library.books.first {
                select(first.id)
            }
        }
        if let mode = ProcessInfo.processInfo.environment["MARGINS_DELETE_FIXTURE"] {
            for _ in 0..<50 where library.books.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let book = library.books.first else { return }
            bookPendingDeletion = book
            if mode == "confirm" {
                try? await Task.sleep(for: .seconds(1.5))
                await library.removeBook(id: book.id)
                bookPendingDeletion = nil
            }
        }
    }

    /// Launch with `MARGINS_IMPORT_FIXTURE=/path/to/book.epub` and an empty
    /// library to import a fixture without driving the document picker.
    private func importFixtureIfRequested() async {
        guard library.books.isEmpty,
              let fixture = ProcessInfo.processInfo.environment["MARGINS_IMPORT_FIXTURE"],
              FileManager.default.fileExists(atPath: fixture)
        else { return }
        await library.importEpubs(atPaths: [fixture])
    }
    #endif
}

/// Grid cell: cover (or placeholder), title, author, note count, and a
/// reading-progress bar from `progress_percent`. Wrapped in a `Button` by
/// the grid so VoiceOver sees an action, not a tap gesture.
struct BookGridCell: View {
    let book: BookSummary
    var zoomNamespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(coverPath: book.coverPath, title: book.title)
                .frame(height: 150)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.cover, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .matchedTransitionSource(id: book.id, in: zoomNamespace)
            Text(book.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 6) {
                Text(book.notesCount == 1 ? "1 note" : "\(book.notesCount) notes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let progress = book.progressPercent {
                    ProgressView(value: progress, total: 100)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(width: 34)
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(book.title) by \(book.author), \(book.notesCount) notes" +
                (book.progressPercent.map { String(format: ", %.0f%% read", $0) } ?? "")
        )
    }
}
