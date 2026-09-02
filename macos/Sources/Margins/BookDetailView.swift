import SwiftUI
import MarginsCore

struct BookDetailView: View {
    let book: BookMeta

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Author", value: book.author)
                if let language = book.language {
                    LabeledContent("Language", value: language)
                }
                LabeledContent("Source file", value: book.sourceFilename)
                LabeledContent("Added", value: addedText)
            }
            Section("Chapters (\(book.chapters.count))") {
                ForEach(book.chapters) { chapter in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(chapter.index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Text(chapter.title)
                    }
                }
            }
        }
        .navigationTitle(book.title)
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
