import SwiftUI
import MarginsCore

struct BookRowView: View {
    let book: BookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
            Text(book.author)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
