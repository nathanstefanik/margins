import SwiftUI
import MarginsCore
import MarginsModel

/// The compiled notes page: every chapter note in spine order, with a
/// stats header, an outline view (chapter/title list) and a contents view
/// (the compiled document — `t` or the segmented control flips between
/// them), and one-click markdown export. Matches `BookDetailView`'s
/// visual language (serif title, 720pt max width).
struct NotesPageView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    let notes: CompiledNotes

    @State private var showingClearDialog = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if notes.chapters.isEmpty {
                        emptyState
                    } else if model.notesPageTab == .outline {
                        outlineView(proxy: proxy)
                    } else {
                        sectionList
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
        }
        .navigationTitle("Notes — \(notes.bookTitle)")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.showBookDetail()
                } label: {
                    Label("Back to Book", systemImage: "chevron.left")
                }
                .help("Back to the book detail (Esc)")
            }
        }
        .confirmationDialog(
            "Clear All Notes?",
            isPresented: $showingClearDialog,
            titleVisibility: .visible
        ) {
            Button("Clear All Notes", role: .destructive) {
                clearAllNotes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete every chapter note for \"\(notes.bookTitle)\"? This cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notes.bookTitle)
                .font(.system(.largeTitle, design: .serif))
                .lineLimit(3)
            Text(notes.bookAuthor)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(LibraryModel.statsLine(for: notes))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Picker("View", selection: tabBinding) {
                    Text("Outline").tag(LibraryModel.NotesPageTab.outline)
                    Text("Contents").tag(LibraryModel.NotesPageTab.contents)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .help("Toggle outline / contents (t)")

                Button {
                    Task { await ExportNotesPanel.run(model: model, notes: notes) }
                } label: {
                    Label("Export Notes…", systemImage: "square.and.arrow.up")
                }
                Button("Copy Markdown") {
                    copyAll()
                }
                Button(role: .destructive) {
                    showingClearDialog = true
                } label: {
                    Label("Clear All Notes…", systemImage: "trash")
                }
                .disabled(notes.chapters.isEmpty)
                .help("Delete every chapter note for this book")
            }
            .padding(.top, 4)
        }
    }

    private var tabBinding: Binding<LibraryModel.NotesPageTab> {
        Binding(
            get: { model.notesPageTab },
            set: { model.showNotesPageTab($0) }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No notes yet", systemImage: "note.text")
        } description: {
            Text("Press `i` in the reader to write a chapter note.")
        }
    }

    // MARK: Outline (chapter / title list)

    private func outlineView(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(notes.chapters) { chapter in
                outlineRow(chapter, proxy: proxy)
                if chapter.chapterKey != notes.chapters.last?.chapterKey {
                    Divider()
                }
            }
        }
    }

    private func outlineRow(
        _ chapter: CompiledChapter,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            openSection(chapter, proxy: proxy)
        } label: {
            HStack(spacing: 12) {
                Text("\(chapter.chapterIndex + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(chapter.chapterTitle)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(metaText(chapter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .help("Show this note")
    }

    /// Outline → contents: flip the tab, then jump to the section once the
    /// contents view is mounted.
    private func openSection(
        _ chapter: CompiledChapter,
        proxy: ScrollViewProxy
    ) {
        model.showNotesPageTab(.contents)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation {
                proxy.scrollTo(chapter.chapterKey, anchor: .top)
            }
        }
    }

    // MARK: Sections (the contents view)

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes.chapters) { chapter in
                sectionRow(chapter)
                if chapter.chapterKey != notes.chapters.last?.chapterKey {
                    Divider()
                }
            }
        }
    }

    private func sectionRow(_ chapter: CompiledChapter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                openChapter(chapter)
            } label: {
                HStack(spacing: 12) {
                    Text("\(chapter.chapterIndex + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 26, alignment: .trailing)
                    Text(chapter.chapterTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Image(systemName: "arrow.up.forward")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Open this chapter in the reader")

            Text(metaText(chapter))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !chapter.body.isEmpty {
                // User markdown stays plain text; real markdown rendering
                // (`AttributedString(markdown:)`) is a stretch goal.
                Text(chapter.body)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }

            // Marks render as styled quotes/notes — never as the raw HTML
            // comments they are on disk; plain Text only, like note bodies.
            let marks = MarkDisplay.sortedForDisplay(chapter.marks)
            if !marks.isEmpty {
                Text(MarkDisplay.countText(marks.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(marks, id: \.id) { mark in
                    markBlock(mark)
                }
                .padding(.bottom, 8)
            }
        }
        .id(chapter.chapterKey)
    }

    private func markBlock(_ mark: Mark) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !mark.quote.isEmpty {
                Text(mark.quote)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !mark.body.isEmpty {
                Text(mark.body)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            let attribution = MarkDisplay.attribution(percent: mark.percent, at: mark.at)
            if !attribution.isEmpty {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaText(_ chapter: CompiledChapter) -> String {
        var parts = ["\(LibraryModel.groupedCount(chapter.wordCount)) words"]
        if !chapter.marks.isEmpty {
            parts.append(MarkDisplay.countText(chapter.marks.count))
        }
        if let updated = chapter.updatedAt {
            parts.append("updated \(LibraryModel.dateText(updated))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func openChapter(_ chapter: CompiledChapter) {
        guard let book = model.selectedBook, book.id == notes.bookId,
              let meta = book.chapters.first(where: { $0.key == chapter.chapterKey })
        else { return }
        reader.open(book: book, chapter: meta)
    }

    private func copyAll() {
        Task {
            do {
                let markdown = try await model.renderNotesMarkdown(bookId: notes.bookId)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(markdown, forType: .string)
            } catch {
                model.errorMessage = String(describing: error)
            }
        }
    }

    /// Clears every note for this book. The model recompiles the cached
    /// compiled page, so the emptied state shows immediately.
    private func clearAllNotes() {
        Task {
            await model.clearNotes(bookId: notes.bookId)
        }
    }
}
