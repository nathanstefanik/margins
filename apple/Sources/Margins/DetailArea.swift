import MarginsCore
import MarginsModel
import SwiftUI

struct DetailArea: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ClubModel.self) private var clubs
    @Environment(ReaderModel.self) private var reader

    var body: some View {
        if reader.isOpen {
            ReaderView()
        } else if clubs.selectedClub != nil {
            ClubDetailView()
        } else if model.detailMode == .notes, let notes = model.compiledNotes {
            NotesPageView(notes: notes)
        } else if let book = model.selectedBook {
            BookDetailView(book: book)
        } else if model.books.isEmpty {
            ContentUnavailableView {
                Label("No books yet", systemImage: "book")
            } description: {
                Text("Import an EPUB to start your library.")
            } actions: {
                Button("Import EPUB…") {
                    Task { await ImportPanel.run(model: model) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let book = model.continueBook {
            ContinueReadingCard(book: book, chapterTitle: model.continueChapterTitle)
        } else {
            ContentUnavailableView(
                "No book selected",
                systemImage: "sidebar.left",
                description: Text("Choose a book from the sidebar.")
            )
        }
    }
}

/// The empty detail's resume card: while nothing is selected, the most
/// recently read book offers itself — one click (or Enter) back into it.
private struct ContinueReadingCard: View {
    @Environment(LibraryModel.self) private var model
    let book: BookSummary
    let chapterTitle: String?

    var body: some View {
        VStack(spacing: 10) {
            BookCoverView(
                coverPath: book.coverPath,
                title: book.title,
                width: 140,
                height: 210
            )
            .padding(.bottom, 6)
            Text(book.title)
                .font(.system(.title2, design: .serif))
                .lineLimit(3)
                .multilineTextAlignment(.center)
            Text(book.author)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let chapterTitle {
                Text(chapterTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let percent = book.progressPercent {
                Text("\(Int(percent.rounded()))% read")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.openBookResuming(id: book.id) }
            } label: {
                Label("Continue Reading", systemImage: "book.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Resume reading (Enter)")
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
