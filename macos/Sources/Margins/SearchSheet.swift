import SwiftUI
import MarginsCore
import MarginsModel

struct SearchSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [NoteSearchHit] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search notes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit {
                    openFirstHit()
                }
            if query.isEmpty {
                ContentUnavailableView(
                    "Search your notes",
                    systemImage: "magnifyingglass",
                    description: Text("Type to search across every chapter note.")
                )
            } else if hits.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Nothing found for “\(query)”.")
                )
            } else {
                List(hits) { hit in
                    Button {
                        open(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(hit.bookTitle) — \(hit.chapterTitle)")
                                .font(.headline)
                            Text(hit.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 460)
        .task(id: query) {
            // Rapid typing can complete tasks out of order; discard stale ones.
            let searched = query
            let results = await model.searchNotes(searched)
            if searched == query {
                hits = results
            }
        }
        .onAppear {
            fieldFocused = true
        }
    }

    private func openFirstHit() {
        guard let hit = hits.first else { return }
        open(hit)
    }

    private func open(_ hit: NoteSearchHit) {
        Task {
            guard let book = await model.getBook(id: hit.bookId),
                  let chapter = book.chapters.first(where: { $0.key == hit.chapterKey })
            else { return }
            reader.open(book: book, chapter: chapter)
            dismiss()
        }
    }
}
