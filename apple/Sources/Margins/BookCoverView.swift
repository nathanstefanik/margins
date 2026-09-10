import AppKit
import SwiftUI
import MarginsCore
import MarginsModel

/// A book's cover at a fixed ~2:3 size. Books with a cover show the image;
/// the rest get a deterministic placeholder — letterpress-style initials on
/// a tint derived from the title — so the shelf never looks broken.
struct BookCoverView: View {
    let coverPath: String?
    let title: String
    let width: CGFloat
    let height: CGFloat

    /// Covers are few and small; one entry per path keeps row re-renders off
    /// the disk. NSCache is thread-safe and evicts under memory pressure.
    private static let cache = NSCache<NSString, NSImage>()

    /// System palette tints for placeholders (chrome uses system colors).
    private static let tints: [Color] = [.indigo, .teal, .orange, .pink, .purple, .mint, .blue, .green]

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

    private var placeholder: some View {
        let tint = Self.tints[
            BookCoverPlaceholder.tintIndex(for: title, paletteSize: Self.tints.count)
        ]
        return ZStack {
            tint.opacity(0.8)
            Text(BookCoverPlaceholder.initials(for: title))
                .font(.system(size: max(height * 0.28, 10), weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
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
