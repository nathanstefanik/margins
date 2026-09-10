import SwiftUI
import MarginsKernel

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
                if let percent = book.progressPercent, percent > 0 {
                    ProgressView(value: min(percent, 100), total: 100)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
