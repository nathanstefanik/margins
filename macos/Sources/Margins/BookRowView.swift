import SwiftUI
import MarginsCore

struct BookRowView: View {
    let book: BookSummary

    var body: some View {
        HStack(spacing: 10) {
            BookCoverView(
                coverPath: book.coverPath,
                title: book.title,
                width: 34,
                height: 51
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .lineLimit(1)
                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
