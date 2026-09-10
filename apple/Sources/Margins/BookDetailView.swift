import SwiftUI
import MarginsKernel
import MarginsModel

struct BookDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    let book: BookMeta

    /// The chapter list has two faces: the plain spine (default — easiest
    /// for navigating to any chapter) and a "Show Notes" view listing only
    /// the annotated chapters with their stats. Persisted across launches.
    @AppStorage("bookDetailShowsNotes") private var showsNotes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                chapterList
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .navigationTitle(book.title)
        .task(id: book.id) {
            // Coming back from the reader: percent and note indicators were
            // captured before the reading session; refresh them.
            await model.loadSelectedBook()
        }
    }

    // MARK: Hero header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            BookCoverView(
                coverPath: book.coverPath,
                title: book.title,
                width: 132,
                height: 198
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.system(.largeTitle, design: .serif))
                    .lineLimit(3)
                Text(book.author)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !book.chapters.isEmpty {
                    HStack {
                        Button {
                            Task { await model.openBookResuming(id: book.id) }
                        } label: {
                            Label("Read", systemImage: "book.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("Resume reading (Enter)")
                        Button {
                            Task { await model.loadCompiledNotes(bookId: book.id) }
                        } label: {
                            Label("All Notes", systemImage: "note.text")
                        }
                        .controlSize(.large)
                        .help("Compiled notes page (N)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let language = book.language {
            parts.append(language)
        }
        parts.append("Added \(addedText)")
        parts.append("\(book.chapters.count) chapters")
        if let percent = book.progressPercent {
            parts.append("\(Int(percent.rounded()))% read")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Chapter list

    private var hasAnyNotes: Bool {
        !model.selectedBookNotesIndex.isEmpty
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(showsNotes ? "Notes" : "Chapters")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showsNotes.toggle()
                    }
                } label: {
                    Text(showsNotes ? "Hide Notes" : "Show Notes")
                }
                .buttonStyle(.borderless)
                .disabled(!hasAnyNotes && !showsNotes)
                .help(showsNotes ? "Show the full chapter list" : "Show only chapters with notes")
            }
            .padding(.bottom, 6)

            if showsNotes {
                notesList
            } else {
                chaptersList
            }
        }
    }

    /// The full spine, plain rows: number and title only.
    private var chaptersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(book.chapters) { chapter in
                chapterRow(chapter)
                if chapter.key != book.chapters.last?.key {
                    Divider()
                }
            }
        }
    }

    /// Only the annotated chapters, in spine order, with their note stats.
    private var notesList: some View {
        let rows = LibraryModel.annotatedChapterRows(
            chapters: book.chapters,
            index: model.selectedBookNotesIndex
        )
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No notes yet — press `i` in the reader to write one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(rows, id: \.chapter.key) { row in
                    noteRow(row)
                    if row.chapter.key != rows.last?.chapter.key {
                        Divider()
                    }
                }
            }
        }
    }

    private func chapterRow(_ chapter: ChapterMeta) -> some View {
        Button {
            openReader(chapter)
        } label: {
            HStack(spacing: 12) {
                Text("\(chapter.index + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(chapter.title)
                    .lineLimit(2)
                    .padding(.vertical, 8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func noteRow(_ row: LibraryModel.ChapterNoteRow) -> some View {
        Button {
            openReader(row.chapter)
        } label: {
            HStack(spacing: 12) {
                Text("\(row.chapter.index + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(row.chapter.title)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(noteRowMeta(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("This chapter has a note — open it in the reader")
    }

    private func noteRowMeta(_ row: LibraryModel.ChapterNoteRow) -> String {
        var parts = ["\(LibraryModel.groupedCount(row.wordCount)) words"]
        if let updated = row.updatedAt {
            parts.append("updated \(LibraryModel.dateText(updated))")
        }
        return parts.joined(separator: " · ")
    }

    private func openReader(_ chapter: ChapterMeta) {
        reader.open(book: book, chapter: chapter)
    }

    private var addedText: String {
        book.addedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
