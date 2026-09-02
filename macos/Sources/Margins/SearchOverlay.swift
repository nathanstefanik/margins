import SwiftUI
import MarginsCore
import MarginsModel

/// Non-modal, Spotlight-style note search overlaid inside the main window.
/// Dismissal: Esc (routed through the shell key monitor to
/// `requestSearchDismissal`), clicking anywhere outside the panel, or
/// opening a hit. Non-modal on purpose: no sheet windows, no AppKit modal
/// session, no field-editor key fights — one window, one responder chain.
struct SearchOverlay: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var hits: [NoteSearchHit] = []

    var body: some View {
        ZStack {
            // Click-away scrim: a click anywhere outside the panel closes.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.requestSearchDismissal() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search notes…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onSubmit {
                            openFirstHit()
                        }
                    Text("esc")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                }
                .padding(12)

                Divider()

                results
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .frame(width: 580)
            .padding(.top, 48)
            // Keep clicks on the panel's blank areas from closing it.
            .contentShape(.rect)
            .onTapGesture {}
        }
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
        .onDisappear {
            fieldFocused = false
        }
        .onExitCommand {
            model.requestSearchDismissal()
        }
    }

    @ViewBuilder
    private var results: some View {
        if query.isEmpty {
            hint("Type to search across every chapter note.")
        } else if hits.isEmpty {
            hint("No matches for “\(query)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(hits) { hit in
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 340)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
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
            model.requestSearchDismissal()
        }
    }
}
