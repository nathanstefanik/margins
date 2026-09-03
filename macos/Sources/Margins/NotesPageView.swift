import SwiftUI
import MarginsCore
import MarginsModel

/// The compiled notes page: every chapter note in spine order, with a
/// stats header, a jump list, and one-click markdown export. Matches
/// `BookDetailView`'s visual language (serif title, 720pt max width).
struct NotesPageView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    let notes: CompiledNotes

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if notes.chapters.isEmpty {
                        emptyState
                    } else {
                        jumpList(proxy)
                        sectionList
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
        }
        .navigationTitle("Notes — \(notes.bookTitle)")
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
                Button {
                    Task { await ExportNotesPanel.run(model: model, notes: notes) }
                } label: {
                    Label("Export Notes…", systemImage: "square.and.arrow.up")
                }
                Button("Copy Markdown") {
                    copyAll()
                }
            }
            .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No notes yet", systemImage: "note.text")
        } description: {
            Text("Press `i` in the reader to write a chapter note.")
        }
    }

    // MARK: Jump list

    private func jumpList(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contents")
                .font(.headline)
            ForEach(notes.chapters) { chapter in
                Button {
                    withAnimation {
                        proxy.scrollTo(chapter.chapterKey, anchor: .top)
                    }
                } label: {
                    Text("\(chapter.chapterIndex + 1). \(chapter.chapterTitle)")
                        .lineLimit(2)
                }
                .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Sections

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes.chapters) { chapter in
                sectionRow(chapter, hasNote: true)
                Divider()
            }
            // Gap visibility: note-less chapters stay listed so the page
            // doubles as a "what's left to annotate" checklist.
            ForEach(notes.emptyChapters) { chapter in
                sectionRow(chapter, hasNote: false)
                if chapter.chapterKey != notes.emptyChapters.last?.chapterKey {
                    Divider()
                }
            }
        }
    }

    private func sectionRow(_ chapter: CompiledChapter, hasNote: Bool) -> some View {
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
                        .foregroundStyle(hasNote ? .primary : .secondary)
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
            .help(hasNote ? "Open this chapter in the reader" : "No note yet — open the chapter")

            Text(metaText(chapter, hasNote: hasNote))
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNote, !chapter.body.isEmpty {
                // User markdown stays plain text; real markdown rendering
                // (`AttributedString(markdown:)`) is a stretch goal.
                Text(chapter.body)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .id(chapter.chapterKey)
    }

    private func metaText(_ chapter: CompiledChapter, hasNote: Bool) -> String {
        if !hasNote {
            return "No note."
        }
        var parts = ["\(LibraryModel.groupedCount(chapter.wordCount)) words"]
        if let updated = chapter.updatedAt.flatMap(LibraryModel.parseRFC3339) {
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
}
