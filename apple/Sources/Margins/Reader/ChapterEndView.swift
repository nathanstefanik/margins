import MarginsCore
import MarginsModel
import SwiftUI

/// The end-of-chapter page: an opaque paper sheet over the reading column
/// that pauses once per finished chapter — a couple of its marked quotes,
/// a taste of its note, and the offer to write something. Any key
/// dismisses it (the shell key monitor owns that); `i` writes a thought.
struct ChapterEndView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader

    let chapter: ChapterMeta
    @State private var content: ChapterEndContent?

    private var theme: ReaderTheme { reader.preferences.theme }

    private var face: String { reader.preferences.typeface.familyName }

    var body: some View {
        ZStack {
            Paper.background(theme)
            VStack(alignment: .leading, spacing: 18) {
                Text(content?.label ?? "END OF CHAPTER")
                    .font(.system(size: 11, weight: .medium, design: .serif).smallCaps())
                    .tracking(1.2)
                    .foregroundStyle(Paper.secondaryInk(theme))
                Text(chapter.title)
                    .font(.custom(face, size: 22, relativeTo: .title2).weight(.semibold))
                    .foregroundStyle(Paper.ink(theme))
                    .lineLimit(4)

                if let content {
                    ForEach(content.quotes.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle()
                                .fill(Paper.secondaryInk(theme).opacity(0.35))
                                .frame(width: 2)
                            Text(content.quotes[index])
                                .font(.custom(face, size: 14, relativeTo: .body).italic())
                                .foregroundStyle(Paper.ink(theme))
                                .lineLimit(4)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !content.excerpt.isEmpty {
                        Text(content.excerpt)
                            .font(.callout)
                            .foregroundStyle(Paper.secondaryInk(theme))
                            .lineLimit(2)
                    }
                }

                Text("Anything worth keeping?")
                    .font(.callout)
                    .foregroundStyle(Paper.secondaryInk(theme))

                HStack(spacing: 12) {
                    Button("Write a thought") { writeThought() }
                        .buttonStyle(.borderedProminent)
                    Button("Continue") { reader.dismissChapterEnd() }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: chapter.key) {
            guard let book = reader.book else { return }
            content = await model.chapterEndContent(for: chapter, in: book)
        }
    }

    /// Step back into the finished chapter and open the notes pane on it
    /// (the reader has already advanced into the successor).
    private func writeThought() {
        Self.leave(chapter, writing: true, reader: reader)
    }

    /// Leave the chapter-end page. `writing` also steps the reader back
    /// into the finished chapter and opens its notes pane; plain continue
    /// leaves the reader on the successor's first page. Shared by the
    /// button and the shell key monitor.
    static func leave(_ chapter: ChapterMeta, writing: Bool, reader: ReaderModel) {
        reader.dismissChapterEnd()
        guard writing, let book = reader.book else { return }
        reader.open(book: book, chapter: chapter)
        ReaderController.evaluateInReader(
            "readerDisplay(\(ReaderController.javaScriptLiteral(reader.displayTarget)))")
        reader.openNotes()
    }
}
