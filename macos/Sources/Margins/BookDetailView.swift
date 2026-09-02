import SwiftUI
import MarginsCore
import MarginsModel

struct BookDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    let book: BookMeta

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
                    Button {
                        Task { await model.openBookResuming(id: book.id) }
                    } label: {
                        Label("Read", systemImage: "book.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Resume reading (Enter)")
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

    private var noteWordCounts: [String: UInt32] {
        LibraryModel.noteWordCounts(
            chapters: book.chapters,
            index: model.selectedBookNotesIndex
        )
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chapters")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(book.chapters) { chapter in
                chapterRow(chapter)
                if chapter.key != book.chapters.last?.key {
                    Divider()
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
                Spacer(minLength: 12)
                if let count = noteWordCounts[chapter.key] {
                    Label("\(count) words", systemImage: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help("This chapter has a note")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func openReader(_ chapter: ChapterMeta) {
        reader.open(book: book, chapter: chapter)
    }

    private var addedText: String {
        if let date = Self.parseRFC3339(book.addedAt) {
            date.formatted(date: .abbreviated, time: .shortened)
        } else {
            book.addedAt
        }
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        for includingFractionalSeconds in [true, false] {
            let style = Date.ISO8601FormatStyle(
                dateTimeSeparator: .standard,
                timeZoneSeparator: .colon,
                includingFractionalSeconds: includingFractionalSeconds
            )
            if let date = try? Date(value, strategy: style) {
                return date
            }
        }
        return nil
    }
}
