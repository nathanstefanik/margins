import Foundation

/// The resolved paper palette for a `ReaderTheme`: background, ink,
/// secondary ink, and whether it is a dark paper.
///
/// The single Swift-side source of truth for the reading surface's
/// colors. `reader.js` (`READER_THEMES`) and `reader.html`'s pre-paint
/// carry the same hexes — `ReaderResourceTests` asserts they match, so
/// the copies cannot drift.
public struct ReaderPalette: Equatable, Sendable {
    /// An sRGB channel triplet kept as 0–255 ints so the values compare
    /// byte-for-byte with the hex strings the reader resources carry.
    public struct RGB: Equatable, Sendable {
        public let red: Int
        public let green: Int
        public let blue: Int

        public init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// "#f4f1ea" — the form `reader.js` and `reader.html` carry.
        public var hex: String {
            String(format: "#%02x%02x%02x", red, green, blue)
        }
    }

    public let background: RGB
    public let ink: RGB
    /// Muted ink for secondary text on the paper (footer chapter title).
    public let secondaryInk: RGB
    public let isDark: Bool

    public init(background: RGB, ink: RGB, secondaryInk: RGB, isDark: Bool) {
        self.background = background
        self.ink = ink
        self.secondaryInk = secondaryInk
        self.isDark = isDark
    }
}

public extension ReaderTheme {
    /// The paper this theme paints.
    var palette: ReaderPalette {
        switch self {
        case .light:
            ReaderPalette(
                background: .init(244, 241, 234),
                ink: .init(17, 17, 17),
                secondaryInk: .init(110, 104, 94),
                isDark: false
            )
        case .sepia:
            ReaderPalette(
                background: .init(239, 230, 210),
                ink: .init(46, 37, 25),
                secondaryInk: .init(122, 106, 85),
                isDark: false
            )
        case .dark:
            ReaderPalette(
                background: .init(27, 26, 24),
                ink: .init(230, 226, 218),
                secondaryInk: .init(168, 161, 150),
                isDark: true
            )
        case .night:
            ReaderPalette(
                background: .init(15, 14, 13),
                ink: .init(169, 163, 152),
                secondaryInk: .init(111, 106, 98),
                isDark: true
            )
        }
    }
}
