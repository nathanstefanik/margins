import SwiftUI
import MarginsCore
import MarginsModel

struct BookDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    let book: BookMeta

    /// The chapter list has two faces: the plain spine (default — easiest
    /// for navigating to any chapter) and a "Show Notes" view listing only
    /// the annotated chapters with their stats. Persisted across launches.
    @AppStorage("bookDetailShowsNotes") private var showsNotes = false
    @State private var frontExpanded = false
    @State private var backExpanded = false

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
        parts.append("\(ContentsOutline.build(from: book.chapters).numberedChapterCount) chapters")
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

    /// The book's outline: parts and books as headings, leaf chapters
    /// numbered from one, front and back matter in collapsed groups.
    private var chaptersList: some View {
        let outline = ContentsOutline.build(from: book.chapters)
        return VStack(alignment: .leading, spacing: 0) {
            if !outline.front.isEmpty {
                DisclosureGroup(isExpanded: $frontExpanded) {
                    ForEach(outline.front) { row in
                        outlineRow(row)
                    }
                } label: {
                    matterGroupLabel("Front matter (\(outline.front.count))")
                }
                .padding(.vertical, 4)
            }
            ForEach(outline.body) { row in
                outlineRow(row)
                if row.id != outline.body.last?.id {
                    Divider()
                }
            }
            if !outline.back.isEmpty {
                DisclosureGroup(isExpanded: $backExpanded) {
                    ForEach(outline.back) { row in
                        outlineRow(row)
                    }
                } label: {
                    matterGroupLabel("Back matter (\(outline.back.count))")
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func matterGroupLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func outlineRow(_ row: OutlineRow) -> some View {
        Button {
            openReader(row)
        } label: {
            HStack(spacing: 12) {
                switch row.kind {
                case let .chapter(number):
                    Text("\(number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 26, alignment: .trailing)
                    Text(row.title)
                        .lineLimit(2)
                        .padding(.vertical, 8)
                case let .heading(level):
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(level) * 14)
                        .padding(.vertical, 6)
                case .matter:
                    Text(row.title)
                        .lineLimit(2)
                        .padding(.vertical, 6)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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

    private func openReader(_ row: OutlineRow) {
        reader.open(book: book, chapter: row.chapter, fragment: row.jumpFragment)
    }

    private func openReader(_ chapter: ChapterMeta) {
        reader.open(book: book, chapter: chapter)
    }

    private var addedText: String {
        book.addedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
