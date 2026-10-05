import MarginsCore
import MarginsModel
import SwiftUI

/// A book's cover. Local files load immediately; an evicted iCloud cover
/// requests a download and keeps the placeholder; a missing cover is the
/// shared typeset placeholder — title and author set on a muted paper.
struct CoverView: View {
    @Environment(AppModel.self) private var app

    let coverPath: String?
    let title: String
    var author: String = ""

    @State private var image: UIImage?

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
        .task(id: "\(coverPath ?? "")#\(app.downloadGeneration)") {
            await load()
        }
    }

    private var placeholder: some View {
        let paper = BookCoverPlaceholder.paper(for: title)
        return GeometryReader { geo in
            let w = geo.size.width
            if w >= 60 {
                TypesetCover(title: title, author: author, paper: paper, width: w)
            } else {
                ZStack {
                    Rectangle().fill(Color(paper.background))
                    Text(BookCoverPlaceholder.initials(for: title))
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(Color(paper.ink))
                }
            }
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

/// The ≥60pt placeholder: a quiet letterpress cover — centred serif title,
/// hairline rule, small-caps author — on a paper tint chosen by title.
/// Shared design with macOS's `BookCoverView` placeholder.
struct TypesetCover: View {
    let title: String
    let author: String
    let paper: CoverPaper
    let width: CGFloat

    private var bg: Color { Color(paper.background) }
    private var ink: Color { Color(paper.ink) }

    var body: some View {
        ZStack {
            bg
            VStack(spacing: width * 0.06) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.custom(ReaderTypeface.serif.familyName, size: max(width * 0.13, 8)).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(ink)
                Rectangle()
                    .fill(ink.opacity(0.35))
                    .frame(width: width * 0.24, height: 1)
                Spacer(minLength: 0)
                if !author.isEmpty {
                    Text(author)
                        .font(.system(size: max(width * 0.075, 7), design: .serif).lowercaseSmallCaps())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ink.opacity(0.85))
                }
            }
            .padding(width * 0.10)
        }
        .overlay(
            Rectangle()
                .strokeBorder(ink.opacity(0.10), lineWidth: 0.5)
        )
    }
}


