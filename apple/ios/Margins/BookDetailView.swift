import SwiftUI
import MarginsCore
import MarginsModel

/// The book detail: cover, metadata, progress, and **Continue reading**;
/// a segmented Contents / Notes pair. Contents rows carry note markers and
/// the current reading position; the Notes tab compiles every chapter note
/// (marks included) with stats, ShareLink export, and clear-all.
struct BookDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader

    var bookID: BookSummary.ID?

    @State private var tab: Tab = .contents
    @State private var showEmptyChapters = false
    @State private var readerActive = false
    @State private var position: ReadingPosition?

    enum Tab: Hashable {
        case contents
        case notes
    }

    var body: some View {
        Group {
            if let meta = selectedMeta {
                detail(meta)
            } else {
                ContentUnavailableView("No book selected", systemImage: "book")
            }
        }
        .task(id: bookID ?? library.selectedBook?.id) {
            // Keyed on the *loaded* book, not the selection id: on iPad the
            // detail is created with `bookID == nil` and follows the sidebar
            // selection, whose metadata lands one async hop after
            // `selectedBookID` changes — keying on the id would run while
            // `selectedMeta` is still nil (no position load, no reader).
            if let bookID, library.selectedBookID != bookID {
                await library.selectBook(id: bookID)
            }
            await loadPosition()
            presentReaderIfPending()
            #if DEBUG
            // Development seam: jump straight into the reader, or preselect
            // the Notes tab, for simulator verification.
            switch ProcessInfo.processInfo.environment["MARGINS_OPEN_FIXTURE"] {
            case "reader":
                if let meta = selectedMeta {
                    await library.openBookResuming(id: meta.id)
                    readerActive = true
                }
            case "notes":
                tab = .notes
            default:
                break
            }
            #endif
        }
        .onChange(of: readerActive) {
            // Returning from the reader: flush the debounced position
            // save so the reload reads the page the user actually left,
            // then refresh the progress markers.
            if !readerActive {
                Task {
                    await reader.flushPositionSaveAndWait()
                    await loadPosition()
                }
            }
        }
        .onChange(of: library.passageJumpGeneration) {
            presentReaderIfPending()
        }
        .navigationTitle(selectedMeta?.title ?? "Book")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedMeta: BookMeta? {
        guard let bookID else { return library.selectedBook }
        return library.selectedBook?.id == bookID ? library.selectedBook : nil
    }

    private func loadPosition() async {
        guard let id = selectedMeta?.id else {
            position = nil
            return
        }
        position = await library.readingPosition(bookId: id)
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ meta: BookMeta) -> some View {
        let summary = library.books.first(where: { $0.id == meta.id })
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    CoverView(coverPath: meta.coverPath, title: meta.title)
                        .frame(width: 110, height: 165)
                        .clipShape(.rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meta.title)
                            .font(.title3.weight(.semibold))
                        Text(meta.author)
                            .foregroundStyle(.secondary)
                        if let progress = summary?.progressPercent {
                            ProgressView(value: progress, total: 100) {
                                Text(String(format: "%.0f%% read", progress))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(meta.chapters.count) chapters · \(summary?.notesCount ?? 0) annotated")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task {
                        await library.openBookResuming(id: meta.id)
                        readerActive = true
                    }
                } label: {
                    Label(continueLabel, systemImage: "book.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Picker("View", selection: $tab) {
                    Text("Contents").tag(Tab.contents)
                    Text("Notes").tag(Tab.notes)
                }
                .pickerStyle(.segmented)

                switch tab {
                case .contents:
                    ContentsList(
                        meta: meta,
                        position: position,
                        onJump: { jump(to: $0, cfi: $1) }
                    )
                case .notes:
                    NotesTab(bookID: meta.id, showEmptyChapters: $showEmptyChapters, onJump: { jump(to: $0, cfi: $1) })
                }
            }
            .padding()
        }
        .navigationDestination(isPresented: $readerActive) {
            ReaderScene()
        }
    }

    private var continueLabel: String {
        position != nil ? "Continue reading" : "Start reading"
    }

    private func presentReaderIfPending() {
        guard library.pendingReaderPresent,
              reader.book?.id == selectedMeta?.id
        else { return }
        library.pendingReaderPresent = false
        readerActive = true
    }

    private func jump(to chapter: ChapterMeta, cfi: String? = nil) {
        guard let book = selectedMeta else { return }
        Task {
            await library.openPassage(bookId: book.id, chapterKey: chapter.key, cfi: cfi)
            presentReaderIfPending()
        }
    }
}

// MARK: Contents

/// The spine: every chapter, with a notes marker (from the notes index)
/// and a bookmark on the current reading position. Tapping opens the
/// reader at that chapter. Empty-chapter filtering belongs on Notes.
private struct ContentsList: View {
    let meta: BookMeta
    let position: ReadingPosition?
    let onJump: (ChapterMeta, String?) -> Void

    private var notedKeys: Set<String> {
        Set(libraryNotesIndex.map(\.chapterKey))
    }

    @Environment(LibraryModel.self) private var library

    private var libraryNotesIndex: [NoteIndexEntry] {
        library.selectedBookNotesIndex
    }

    var body: some View {
        let chapters = meta.chapters
        if chapters.isEmpty {
            Text("This book has no chapters.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chapters, id: \.key) { chapter in
                    row(chapter)
                    if chapter.key != chapters.last?.key {
                        Divider()
                    }
                }
            }
        }
    }

    private func row(_ chapter: ChapterMeta) -> some View {
        Button {
            onJump(chapter, nil)
        } label: {
            HStack(spacing: 12) {
                Text("\(chapter.index + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
                Text(chapter.title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notedKeys.contains(chapter.key) {
                    Image(systemName: "pencil.line")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Has notes")
                }
                if position?.chapterKey == chapter.key {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current reading position")
                }
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Chapter \(chapter.index + 1), \(chapter.title)"
                + (notedKeys.contains(chapter.key) ? ", has notes" : "")
        )
    }
}

// MARK: Notes tab

/// The compiled notes view: stats header, one section per annotated
/// chapter (marks included, in reading order), ShareLink export, and
/// clear-all behind confirmation. Note bodies are plain `Text`, never
/// markdown or HTML.
private struct NotesTab: View {
    @Environment(LibraryModel.self) private var library
    let bookID: String
    @Binding var showEmptyChapters: Bool
    let onJump: (ChapterMeta, String?) -> Void

    @State private var exportMarkdown: String?
    @State private var showClearDialog = false

    var body: some View {
        Group {
            if let notes = library.compiledNotes, notes.bookId == bookID {
                compiled(notes)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Compiling notes…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
        }
        .task(id: bookID) {
            await library.loadCompiledNotes(bookId: bookID)
        }
        .onChange(of: library.compiledNotes) {
            // The cached export is a snapshot: new marks, saved notes, or
            // a clear-all must invalidate it, or the ShareLink keeps
            // sharing stale markdown.
            exportMarkdown = nil
        }
    }

    @ViewBuilder
    private func compiled(_ notes: CompiledNotes) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LibraryModel.statsLine(for: notes))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Show chapters without notes", isOn: $showEmptyChapters)
                .font(.footnote)

            HStack {
                if let exportMarkdown {
                    ShareLink(item: exportMarkdown, preview: SharePreview(notes.suggestedFilename)) {
                        Label("Export .md", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task { await prepareExport(bookId: notes.bookId) }
                    } label: {
                        Label("Export .md", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    showClearDialog = true
                } label: {
                    Label("Clear All…", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .confirmationDialog(
                "Clear All Notes?",
                isPresented: $showClearDialog,
                titleVisibility: .visible
            ) {
                Button("Clear All Notes", role: .destructive) {
                    Task { await library.clearNotes(bookId: notes.bookId) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Delete every chapter note for \"\(notes.bookTitle)\"? This cannot be undone.")
            }

            ForEach(notes.chapters) { chapter in
                section(chapter)
            }
            if showEmptyChapters {
                ForEach(notes.emptyChapters) { chapter in
                    emptyStub(chapter)
                }
            }
            if notes.chapters.isEmpty && !showEmptyChapters {
                Text("No notes yet — write one while reading (Phase 6), or from a chapter in Contents.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ chapter: CompiledChapter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let meta = library.selectedBook,
                   let target = meta.chapters.first(where: { $0.key == chapter.chapterKey }) {
                    onJump(target, nil)
                }
            } label: {
                HStack(spacing: 8) {
                    Text("\(chapter.chapterIndex + 1). \(chapter.chapterTitle)")
                        .font(.headline)
                        .lineLimit(2)
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Text(chapterMetaLine(chapter))
                .font(.caption)
                .foregroundStyle(.secondary)

            // User markdown stays plain text — a security property, not a
            // style choice.
            if !chapter.body.isEmpty {
                Text(chapter.body)
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(MarkDisplay.sortedForDisplay(chapter.marks), id: \.id) { mark in
                markBlock(mark, chapter: chapter)
            }
        }
        .padding(.vertical, 6)
    }

    private func markBlock(_ mark: Mark, chapter: CompiledChapter) -> some View {
        Button {
            if let meta = library.selectedBook,
               let target = meta.chapters.first(where: { $0.key == chapter.chapterKey }) {
                onJump(target, mark.cfi)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if !mark.quote.isEmpty {
                    Text(mark.quote)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                if !mark.body.isEmpty {
                    Text(mark.body)
                        .font(.callout)
                }
                let attribution = MarkDisplay.attribution(percent: mark.percent, at: mark.at)
                if !attribution.isEmpty {
                    Text(attribution)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the reader at this mark")
    }

    private func emptyStub(_ chapter: CompiledChapter) -> some View {
        Text("\(chapter.chapterIndex + 1). \(chapter.chapterTitle) — no note")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 2)
    }

    private func chapterMetaLine(_ chapter: CompiledChapter) -> String {
        var parts: [String] = []
        let words = chapter.wordCount
        if words > 0 { parts.append("\(words) words") }
        let markCount = chapter.marks.count
        if markCount > 0 { parts.append(MarkDisplay.countText(markCount)) }
        if let updated = chapter.updatedAt.flatMap(LibraryModel.parseRFC3339) {
            parts.append("updated \(LibraryModel.dateText(updated))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func prepareExport(bookId: String) async {
        do {
            exportMarkdown = try await library.renderNotesMarkdown(bookId: bookId)
        } catch {
            library.errorMessage = String(describing: error)
        }
    }
}
