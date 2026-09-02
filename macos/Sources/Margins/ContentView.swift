import SwiftUI
import MarginsCore

struct ContentView: View {
    @State private var model = LibraryModel()

    var body: some View {
        Group {
            if let errorMessage = model.errorMessage {
                ContentUnavailableView(
                    "Could not open library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if model.books.isEmpty {
                ContentUnavailableView(
                    "No books yet",
                    systemImage: "book",
                    description: Text(model.libraryRoot)
                )
            } else {
                List(model.books, id: \.id) { book in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                        Text(book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .overlay(alignment: .bottom) {
            Text(model.libraryRoot)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .task { await model.activate() }
    }
}
