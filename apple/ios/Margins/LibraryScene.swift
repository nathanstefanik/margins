import MarginsCore
import MarginsModel
import SwiftUI
import UniformTypeIdentifiers

/// The app's tab anatomy: **Library**, **Notebooks**, **Clubs**, and
/// **Search**, one information architecture that adapts from a compact
/// floating tab bar to a regular sidebar (`.sidebarAdaptable`) instead of
/// a hand-built per-device layout. Global search owns its own tab — its
/// scope is the whole library — while contextual search belongs over the
/// content it filters.
enum AppTab: Hashable {
    case library
    case notebooks
    case clubs
    case search
}

/// A book pushed onto the Library tab's navigation stack.
enum LibraryRoute: Hashable {
    case book(id: String)
}

struct LibraryScene: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ClubModel.self) private var clubs
    @Environment(AppModel.self) private var app

    @State private var selectedTab: AppTab = .library
    @State private var libraryPath: [LibraryRoute] = []
    /// The Notebooks stack: pushed values are notebook ids.
    @State private var notebooksPath: [String] = []
    @State private var importPresented = false
    @State private var bookPendingDeletion: BookSummary?
    @State private var readerActive = false
    /// Which `matchedTransitionSource` the reader zooms out of: a grid
    /// cover is its book id, the continue card is `"continue-<id>"`.
    @State private var zoomSourceID = ""

    /// Shared by the grid covers and the reader so the reader grows out of
    /// the cover that was tapped.
    @Namespace private var zoomNamespace

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                libraryTab
            }
            Tab("Notebooks", systemImage: "text.book.closed", value: AppTab.notebooks) {
                NotebooksScene(path: $notebooksPath)
            }
            Tab("Clubs", systemImage: "person.2", value: AppTab.clubs) {
                ClubsScene()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                searchTab
            }
        }
        .environment(
            \.openPassage,
            OpenPassageAction { target in
                Task { await openPassageTarget(target) }
            }
        )
        .environment(
            \.openNotebook,
            OpenNotebookAction { notebookId in
                selectedTab = .notebooks
                notebooksPath = [notebookId]
            }
        )
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
                            ReaderScene(
                                zoomNamespace: zoomNamespace,
                                zoomSourceID: zoomSourceID
                            )
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
                        Task { await app.removeBook(id: book.id) }
                    }
                    Button("Cancel", role: .cancel) {
                        bookPendingDeletion = nil
                    }
                } message: {
                    Text(
                        "Remove \"\(bookPendingDeletion?.title ?? "")\" and its notes from the library? The original EPUB file is untouched."
                    )
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
        if library.books.isEmpty && library.notDownloadedBookIDs.isEmpty {
            ContentUnavailableView {
                Label("No books yet", systemImage: "book")
            } description: {
                Text("Import an EPUB to start reading and taking notes.")
            } actions: {
                Button {
                    importPresented = true
                } label: {
                    Text("Import EPUB")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            ScrollView {
                libraryStatusHeader
                continueCard
                if !library.books.isEmpty {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 104, maximum: 160), spacing: DesignTokens.Spacing.gridCell)
                        ],
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
                                if book.lastReadAt != nil {
                                    Button {
                                        openContinue(book: book, zoomSourceID: book.id)
                                    } label: {
                                        Label("Continue reading", systemImage: "book")
                                    }
                                }
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
    }

    /// The resume hero above the grid: the most recently read book's
    /// cover, where it stopped, and one tap back into the reader. It is
    /// content, so it sits on the plain canvas — a quiet fill, no glass.
    @ViewBuilder
    private var continueCard: some View {
        if let book = library.continueBook {
            Button {
                openContinue(book: book, zoomSourceID: "continue-\(book.id)")
            } label: {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.gridCell) {
                    CoverView(coverPath: book.coverPath, title: book.title)
                        .frame(width: 96, height: 144)
                        .clipShape(
                            .rect(cornerRadius: DesignTokens.Radius.cover, style: .continuous)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        .matchedTransitionSource(
                            id: "continue-\(book.id)", in: zoomNamespace
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Continue reading", systemImage: "book.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(book.title)
                            .font(.system(.title3, design: .serif).weight(.semibold))
                            .lineLimit(2)
                        if let chapter = library.continueChapterTitle {
                            Text(chapter)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let progress = book.progressPercent {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(format: "%.0f%% read", progress))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ProgressView(value: progress, total: 100)
                                    .progressViewStyle(.linear)
                                    .tint(.accentColor)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DesignTokens.Spacing.gridCell)
                .background(
                    Color(.secondarySystemBackground),
                    in: .rect(cornerRadius: DesignTokens.Radius.card)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, DesignTokens.Spacing.gridCell)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Continue reading \(book.title)")
            .accessibilityValue(
                book.progressPercent.map { String(format: "%.0f%% read", $0) } ?? ""
            )
        }
    }

    private func select(_ id: String) {
        Task {
            zoomSourceID = id
            await library.selectBook(id: id)
            libraryPath.append(.book(id: id))
        }
    }

    /// Straight into the reader at the saved position: the detail goes on
    /// the stack underneath so Back lands there, and `pendingReaderPresent`
    /// lets the detail push the reader once it is up (the same hop the
    /// passage-open path uses).
    private func openContinue(book: BookSummary, zoomSourceID source: String) {
        Task {
            zoomSourceID = source
            guard await app.prepareForReading(bookId: book.id) else { return }
            await library.openBookResuming(id: book.id)
            library.pendingReaderPresent = true
            libraryPath = [.book(id: book.id)]
        }
    }

    // MARK: Search tab

    private var searchTab: some View {
        NavigationStack {
            LibrarySearchView(search: app.search, mode: .browse)
        }
    }

    /// A passage-like result opens the reader inside the Library tab;
    /// switching tabs and rebuilding the path keeps the reader in the same
    /// navigation tree the grid owns rather than a detached one. From
    /// inside the reader the passage-jump generation retargets the visible
    /// page instead of repushing.
    private func openPassageTarget(_ target: PassageTarget) async {
        guard await app.prepareForReading(bookId: target.bookId) else { return }
        await library.openPassage(
            bookId: target.bookId,
            chapterKey: target.chapterKey,
            cfi: target.cfi,
            revealText: target.revealText,
            markId: target.markId
        )
        selectedTab = .library
        zoomSourceID = target.bookId
        libraryPath = [.book(id: target.bookId)]
    }

    // MARK: Status

    @ViewBuilder
    private var libraryStatusHeader: some View {
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
        if app.pendingDownloads > 0, app.connectivity.isOnline {
            let n = app.pendingDownloads
            HStack(spacing: 8) {
                ProgressView()
                Text("Downloading \(n) \(n == 1 ? "file" : "files") from iCloud…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        } else if !library.notDownloadedBookIDs.isEmpty {
            let n = library.notDownloadedBookIDs.count
            let noun = n == 1 ? "book" : "books"
            let suffix = app.connectivity.isOnline ? "" : " — offline"
            Label(
                "\(n) \(noun) waiting for iCloud\(suffix)",
                systemImage: "icloud.and.arrow.down"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var materializingOverlay: some View {
        if app.isMaterializing {
            ZStack {
                Color.black.opacity(0.2).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView("Downloading book…")
                    Button {
                        app.cancelMaterialization()
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Radius.card))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading book from iCloud")
            .accessibilityAction(named: "Cancel") {
                app.cancelMaterialization()
            }
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
        await evictFixtureIfRequested()
        if let search = ProcessInfo.processInfo.environment["MARGINS_SEARCH_FIXTURE"] {
            for _ in 0..<50 where library.books.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Wait out the index build so full-text hits are in before
            // the query lands.
            await app.indexPass()
            selectedTab = .search
            app.search.setQuery(search)
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
                await app.removeBook(id: book.id)
                bookPendingDeletion = nil
            }
        }
        if let mode = ProcessInfo.processInfo.environment["MARGINS_NOTEBOOK_FIXTURE"] {
            await notebookFixture(mode: mode)
        }
        if ProcessInfo.processInfo.environment["MARGINS_CLUB_FIXTURE"] != nil {
            await createClubFixture()
        }
    }

    /// `MARGINS_NOTEBOOK_FIXTURE=1|list|reveal` (with
    /// `MARGINS_IMPORT_FIXTURE`): indexes the imported book, creates the
    /// "Self-deception" notebook, adds the top "lie to yourself" text hit
    /// as a CFI-less passage with commentary, and lands on the notebook
    /// (`1`), the notebooks list (`list`), or opens the passage in context
    /// (`reveal` — the reader's text-match reveal runs and backfills the
    /// new mark's CFI).
    private func notebookFixture(mode: String) async {
        for _ in 0..<50 where library.books.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard library.books.first != nil, let store = library.coreStore else { return }
        await app.indexPass()
        await app.notebooks.activate(store: store)
        var summary = app.notebooks.notebooks.first { $0.title == "Self-deception" }
        if summary == nil {
            summary = await app.notebooks.create(title: "Self-deception")
        }
        guard let summary else { return }
        guard let hits = try? await store.searchBookText(query: "lie to yourself"),
            let hit = hits.first
        else { return }
        let added = await app.notebooks.addPassage(
            notebookId: summary.id,
            source: .selection(
                bookId: hit.bookId, chapterKey: hit.chapterKey,
                cfi: nil, percent: nil, quote: hit.passage),
            commentary: "Zossima's advice — the lie to oneself comes first."
        )
        guard added else { return }
        if mode == "reveal",
            let notebook = try? await store.notebook(id: summary.id),
            let markId = notebook.segments.compactMap({ segment in
                if case .passage(let card) = segment.content { return card.ref.markId }
                return nil
            }).first
        {
            await openPassageTarget(
                PassageTarget(
                    bookId: hit.bookId, chapterKey: hit.chapterKey,
                    revealText: hit.passage, markId: markId))
            return
        }
        selectedTab = .notebooks
        if mode != "list" {
            notebooksPath = [summary.id]
        }
    }

    /// `MARGINS_CLUB_FIXTURE=create`: after the import fixture lands, write
    /// one note, start a local club on that book, publish the snapshot, and
    /// open the Clubs tab. Exercises the whole iOS club surface without
    /// touch synthesis.
    private func createClubFixture() async {
        for _ in 0..<50 where library.books.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard clubs.clubs.isEmpty,
            let summary = library.books.first,
            let meta = await library.getBook(id: summary.id),
            let chapter = meta.chapters.first
        else { return }
        await library.saveChapterNoteText(
            bookId: meta.id, chapterKey: chapter.key,
            body: "A first thought to share with the club."
        )
        var created: Club?
        for _ in 0..<50 {
            created = await clubs.createClub(
                bookId: meta.id, name: "Thursday Readers", displayName: "Reader"
            )
            if created != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if created != nil {
            _ = await clubs.publishOwnSnapshot()
        }
        selectedTab = .clubs
    }

    /// Launch with `MARGINS_IMPORT_FIXTURE=/path/to/book.epub` and an empty
    /// library to import a fixture without driving the document picker.
    private func importFixtureIfRequested() async {
        guard library.books.isEmpty,
            let fixture = ProcessInfo.processInfo.environment["MARGINS_IMPORT_FIXTURE"],
            FileManager.default.fileExists(atPath: fixture)
        else { return }
        await library.importEpubs(atPaths: [fixture])
        await app.indexPass()
    }

    /// Launch with `MARGINS_EVICT_FIXTURE=source|position|meta` after an
    /// import to replace that file with a `.name.icloud` placeholder, so
    /// the simulator can exercise the offline/evicted paths.
    private func evictFixtureIfRequested() async {
        guard let kind = ProcessInfo.processInfo.environment["MARGINS_EVICT_FIXTURE"] else {
            return
        }
        for _ in 0..<50 where library.books.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let book = library.books.first else { return }
        let fileName: String
        switch kind {
        case "source": fileName = "source.epub"
        case "position": fileName = "position.json"
        case "meta": fileName = "meta.json"
        default: return
        }
        let logical = URL(fileURLWithPath: library.libraryRoot)
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent(fileName)
        let placeholder = logical.deletingLastPathComponent()
            .appendingPathComponent("." + fileName + ".icloud")
        try? Data().write(to: placeholder)
        try? FileManager.default.removeItem(at: logical)
        await library.refresh()
        await app.downloadPass()
    }
    #endif
}

/// Grid cell: cover (or placeholder), title, author, note count, and a
/// reading-progress bar from `progress_percent`. Wrapped in a `Button` by
/// the grid so VoiceOver sees an action, not a tap gesture.
struct BookGridCell: View {
    @Environment(AppModel.self) private var app

    let book: BookSummary
    var zoomNamespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(coverPath: book.coverPath, title: book.title)
                .frame(height: 150)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.cover, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .overlay(alignment: .topTrailing) {
                    if !app.isReadableOffline(bookId: book.id) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
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
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label =
            "\(book.title) by \(book.author), \(book.notesCount) notes"
        if let progress = book.progressPercent {
            label += String(format: ", %.0f%% read", progress)
        }
        if !app.isReadableOffline(bookId: book.id) {
            label += ", not downloaded"
        }
        return label
    }
}
