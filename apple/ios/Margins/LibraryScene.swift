import SwiftUI
import UniformTypeIdentifiers
import OSLog
import MarginsCore
import MarginsModel

/// The Library scene: every imported book as a cover grid, import via the
/// document picker, delete with confirmation, and library-wide notes
/// search. NavigationStack on iPhone, NavigationSplitView on iPad.
struct LibraryScene: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppModel.self) private var app

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var query = ""
    @State private var hits: [NoteSearchHit] = []
    @State private var importPresented = false
    @State private var bookPendingDeletion: BookSummary?
    @State private var pushedBook: PushedBook?

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                sidebar
            } detail: {
                // BookDetailView pushes the reader via
                // `navigationDestination(isPresented:)`, which is inert
                // without an enclosing stack (the detail column does not
                // provide one on its own).
                NavigationStack {
                    BookDetailView()
                }
            }
        } else {
            NavigationStack {
                content(onSelect: { pushedBook = PushedBook(id: $0) })
                    .navigationDestination(item: $pushedBook) { pushed in
                        BookDetailView(bookID: pushed.id)
                    }
            }
        }
    }

    // MARK: Containers

    private var sidebar: some View {
        NavigationStack {
            content(onSelect: { id in Task { await library.selectBook(id: id) } })
                .navigationTitle("Margins")
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
    }

    @ViewBuilder
    private func content(onSelect: @escaping (String) -> Void) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        Group {
            if trimmed.isEmpty {
                bookGrid(onSelect: onSelect)
            } else {
                searchResults(onSelect: onSelect)
            }
        }
        .navigationTitle("Margins")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes")
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
        .task(id: query) {
            await runSearch()
        }
        #if DEBUG
        .task {
            // The fixtures must not race the app's library-root pin
            // (`app.activate()`): importing into the pre-switch root and
            // then reading from the pinned one leaves ghosts and
            // not-found errors. Idempotent, and a no-op when the App
            // task already ran it.
            await app.activate()
            await importFixtureIfRequested()
        }
        .task {
            await app.activate()
            // Development seams for simulator verification (no UI-automation
            // tooling in this environment): prefill the search query, and
            // drive the delete-confirmation flow (`prompt` shows the dialog,
            // `confirm` also runs the deletion after a beat).
            if ProcessInfo.processInfo.environment["MARGINS_SEARCH_FIXTURE"] != nil {
                // Wait out the initial load so the query runs against real data.
                for _ in 0..<50 where library.books.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                query = ProcessInfo.processInfo.environment["MARGINS_SEARCH_FIXTURE"] ?? ""
            }
            if ProcessInfo.processInfo.environment["MARGINS_OPEN_FIXTURE"] != nil {
                // Push the first book's detail so the scene flow is
                // reachable without touch synthesis. On iPad the detail
                // column has no push — selecting the book is the
                // equivalent entry into `BookDetailView`.
                for _ in 0..<50 where library.books.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let first = library.books.first {
                    Logger(subsystem: "io.github.nathanstefanik.margins", category: "DEBUG-2f1a").log("OPEN fixture: selecting \(first.id)")
                    if sizeClass == .regular {
                        await library.selectBook(id: first.id)
                    } else {
                        pushedBook = PushedBook(id: first.id)
                    }
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
        #endif
    }

    // MARK: Grid

    @ViewBuilder
    private func bookGrid(onSelect: @escaping (String) -> Void) -> some View {
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
                    columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 16)],
                    spacing: 20
                ) {
                    ForEach(library.books) { book in
                        BookGridCell(book: book)
                            .onTapGesture { onSelect(book.id) }
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

    // MARK: Search

    @ViewBuilder
    private func searchResults(onSelect: @escaping (String) -> Void) -> some View {
        List {
            if hits.isEmpty {
                Text("No notes match.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hits) { hit in
                    Button {
                        onSelect(hit.bookId)
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
        .overlay {
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
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

    // MARK: Import

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            library.errorMessage = String(describing: error)
        case .success(let urls):
            guard let picked = urls.first else { return }
            Task { await importPicked(picked) }
        }
    }

    private func importPicked(_ picked: URL) async {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                picked.stopAccessingSecurityScopedResource()
            }
        }
        do {
            // The picker's grant does not outlive this call; snapshot the
            // file somewhere the core can read freely.
            let staged = try app.libraryLocation.stagedCopy(of: picked)
            await library.importEpubs(atPaths: [staged.path])
        } catch {
            library.errorMessage = String(describing: error)
        }
    }

    #if DEBUG
    /// Development seam for simulator verification: launch with
    /// `MARGINS_IMPORT_FIXTURE=/path/to/book.epub` and an empty library to
    /// import a fixture without driving the document picker by hand.
    private func importFixtureIfRequested() async {
        guard library.books.isEmpty,
              let fixture = ProcessInfo.processInfo.environment["MARGINS_IMPORT_FIXTURE"],
              FileManager.default.fileExists(atPath: fixture)
        else { return }
        await library.importEpubs(atPaths: [fixture])
    }
    #endif
}

/// Navigation item for pushing a book from the library grid.
struct PushedBook: Identifiable, Hashable {
    let id: String
}

/// Grid cell: cover (or placeholder), title, author, note count, and a
/// reading-progress bar from `progress_percent`.
struct BookGridCell: View {
    let book: BookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(coverPath: book.coverPath, title: book.title)
                .frame(height: 150)
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
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
