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
