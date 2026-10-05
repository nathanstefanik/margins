import AppKit
import MarginsCore
import MarginsModel
import SwiftUI

/// A book's cover at a fixed ~2:3 size. Books with a cover show the image;
/// the rest get a deterministic typeset placeholder — the title and author
/// set on a muted paper — so the shelf never looks broken.
struct BookCoverView: View {
    let coverPath: String?
    let title: String
    var author: String = ""
    let width: CGFloat
    let height: CGFloat

    /// Covers are few and small; one entry per path keeps row re-renders off
    /// the disk. NSCache is thread-safe and evicts under memory pressure.
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            if let image = Self.image(for: coverPath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat {
        width < 60 ? 4 : 8
    }

    /// Under 60pt (sidebar rows) there is no room to typeset — initials in
    /// the paper's ink instead.
    private var placeholder: some View {
        let paper = BookCoverPlaceholder.paper(for: title)
        return ZStack {
            if width >= 60 {
                TypesetCover(title: title, author: author, paper: paper, width: width)
            } else {
                Color(paper.background)
                Text(BookCoverPlaceholder.initials(for: title))
                    .font(.system(size: max(height * 0.24, 10), weight: .semibold, design: .serif))
                    .foregroundStyle(Color(paper.ink))
            }
        }
    }

    private static func image(for path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// The ≥60pt placeholder: a quiet letterpress cover — centred serif title,
/// hairline rule, small-caps author — on a paper tint chosen by title.
/// Shared design with iOS's `CoverView` placeholder.
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


