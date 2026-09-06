import SwiftUI
import MarginsCore
import MarginsModel

/// A book's cover, materialized on demand: iCloud placeholders download
/// before the image read (see `LibraryLocation.materializedPath`); books
/// without a cover get the shared `BookCoverPlaceholder` initials + tint.
struct CoverView: View {
    @Environment(AppModel.self) private var app

    let coverPath: String?
    let title: String

    @State private var image: UIImage?

    private static let palette: [Color] = [
        Color(red: 0.29, green: 0.33, blue: 0.44),
        Color(red: 0.36, green: 0.28, blue: 0.30),
        Color(red: 0.24, green: 0.34, blue: 0.31),
        Color(red: 0.38, green: 0.33, blue: 0.24),
        Color(red: 0.31, green: 0.27, blue: 0.40),
        Color(red: 0.27, green: 0.30, blue: 0.35),
    ]

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: coverPath) {
            await load()
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Self.palette[BookCoverPlaceholder.tintIndex(for: title, paletteSize: Self.palette.count)])
            Text(BookCoverPlaceholder.initials(for: title))
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityHidden(true)
    }

    private func load() async {
        image = nil
        guard let coverPath else { return }
        do {
            let resolved = try await app.libraryLocation.materializedPath(for: coverPath)
            image = UIImage(contentsOfFile: resolved)
        } catch {
            // A timed-out download leaves the placeholder up; the cover
            // retries next time the view appears.
            image = nil
        }
    }
}

/// What a tapped book shows until the real detail scenes land in Phase 5
/// (docs/ios-plan.md): cover, metadata, progress — reachable from the
/// library grid and from search hits.
struct BookDetailView: View {
    @Environment(LibraryModel.self) private var library

    var bookID: BookSummary.ID?

    init(bookID: BookSummary.ID? = nil) {
        self.bookID = bookID
    }

    var body: some View {
        Group {
            if let meta = library.selectedBook, meta.id == bookID ?? library.selectedBookID {
                detail(meta)
            } else {
                ContentUnavailableView("No book selected", systemImage: "book")
            }
        }
        .task(id: bookID) {
            if let bookID, library.selectedBookID != bookID {
                await library.selectBook(id: bookID)
            }
        }
        .navigationTitle(library.selectedBook?.title ?? "Book")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detail(_ meta: BookMeta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    CoverView(coverPath: meta.coverPath, title: meta.title)
                        .frame(width: 110, height: 165)
                        .clipShape(.rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meta.title)
                            .font(.title3.weight(.semibold))
                        Text(meta.author)
                            .foregroundStyle(.secondary)
                        if let progress = summaryProgress {
                            ProgressView(value: progress, total: 100) {
                                Text(String(format: "%.0f%% read", progress))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(meta.chapters.count) chapters · \(library.books.first(where: { $0.id == meta.id })?.notesCount ?? 0) annotated")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    // Phase 5: opens the reader at the saved position.
                } label: {
                    Label("Continue reading", systemImage: "book.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                Text("Contents and notes arrive in Phase 5.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private var summaryProgress: Double? {
        guard let id = bookID ?? library.selectedBookID else { return nil }
        return library.books.first(where: { $0.id == id })?.progressPercent
    }
}
