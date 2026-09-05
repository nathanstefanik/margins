import Foundation

/// Deterministic placeholder visuals for books without a cover: initials and
/// a tint index derived from the title. Uses a hand-rolled hash because
/// Swift's `Hasher` is seeded per process and would reshuffle on relaunch.
public enum BookCoverPlaceholder {
    /// Up to two uppercase initials from the leading words of `title`
    /// (e.g. "The Brothers Karamazov" → "BK"). Empty for an empty title.
    public static func initials(for title: String) -> String {
        let words = title
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.contains(where: \.isLetter) }
        let letters = words.prefix(2).compactMap { $0.first(where: \.isLetter) }
        return String(letters.prefix(2)).uppercased()
    }

    /// A stable index into the placeholder tint palette, derived from the
    /// title (FNV-1a so equal titles always map to the same tint).
    public static func tintIndex(for title: String, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in title.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(paletteSize))
    }
}
