import Foundation

/// A muted paper + ink pairing for a typeset placeholder cover. Covers are
/// objects — the palette is the same on light and dark system appearances.
public struct CoverPaper: Sendable, Equatable {
    public var background: ReaderPalette.RGB
    public var ink: ReaderPalette.RGB

    public init(background: ReaderPalette.RGB, ink: ReaderPalette.RGB) {
        self.background = background
        self.ink = ink
    }
}

/// Deterministic placeholder visuals for books without a cover: initials and
/// a tint index derived from the title. Uses a hand-rolled hash because
/// Swift's `Hasher` is seeded per process and would reshuffle on relaunch.
public enum BookCoverPlaceholder {
    /// Up to two uppercase initials from the leading words of `title`
    /// (e.g. "The Brothers Karamazov" → "BK"). Empty for an empty title.
    public static func initials(for title: String) -> String {
        let words =
            title
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.contains(where: \.isLetter) }
        let letters = words.prefix(2).compactMap { $0.first(where: \.isLetter) }
        return String(letters.prefix(2)).uppercased()
    }

    /// A stable index into the placeholder tint palette, derived from the
    /// title (FNV-1a so equal titles always map to the same tint).
    public static func tintIndex(for title: String, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in title.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(paletteSize))
    }

    /// The paper palette for typeset covers: cream, sage, slate, clay,
    /// dusk — background and its ink.
    public static let papers: [CoverPaper] = [
        CoverPaper(
            background: .init(0xED, 0xE4, 0xD3),
            ink: .init(0x3B, 0x32, 0x26)),
        CoverPaper(
            background: .init(0xD9, 0xDF, 0xD0),
            ink: .init(0x2F, 0x3A, 0x2C)),
        CoverPaper(
            background: .init(0xD5, 0xDB, 0xE0),
            ink: .init(0x26, 0x30, 0x3A)),
        CoverPaper(
            background: .init(0xE6, 0xD3, 0xC6),
            ink: .init(0x4A, 0x2E, 0x22)),
        CoverPaper(
            background: .init(0xD9, 0xD3, 0xE2),
            ink: .init(0x35, 0x2D, 0x45)),
    ]

    /// The paper this title's placeholder cover is typeset on — stable for
    /// a given title across launches and platforms.
    public static func paper(for title: String) -> CoverPaper {
        papers[tintIndex(for: title, paletteSize: papers.count)]
    }
}
