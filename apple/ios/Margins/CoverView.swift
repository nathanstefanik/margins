import SwiftUI
import MarginsCore
import MarginsModel

/// A book's cover. Local files load immediately; an evicted iCloud cover
/// requests a download and keeps the placeholder; a missing cover is the
/// shared initials + tint.
struct CoverView: View {
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
        switch LibraryLocation.availability(of: coverPath) {
        case .local:
            image = UIImage(contentsOfFile: coverPath)
        case .evicted:
            LibraryLocation.requestDownload(coverPath)
            image = nil
        case .missing:
            image = nil
        }
    }
}
