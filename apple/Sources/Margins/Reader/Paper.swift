import SwiftUI
import MarginsModel

/// The reading surface's paper palette, mirroring the palettes in
/// `reader.html` / `reader.js`.
///
/// The chrome (sidebars, toolbars, panes) always uses system materials and
/// colors; the reading page is the single place with its own palette, which
/// the reader can flip between light and dark.
enum Paper {
    /// Page background, matching reader.html's `#f4f1ea`.
    static let lightBackground = Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255)

    /// Muted ink for secondary text on light paper (chapter title in the
    /// footer).
    static let lightSecondaryInk = Color(red: 110 / 255, green: 104 / 255, blue: 94 / 255)

    /// Page background, matching reader.html's `#1b1a18`.
    static let darkBackground = Color(red: 27 / 255, green: 26 / 255, blue: 24 / 255)

    /// Muted ink for secondary text on dark paper.
    static let darkSecondaryInk = Color(red: 168 / 255, green: 161 / 255, blue: 150 / 255)

    static func background(_ theme: ReaderTheme) -> Color {
        theme == .dark ? darkBackground : lightBackground
    }

    static func secondaryInk(_ theme: ReaderTheme) -> Color {
        theme == .dark ? darkSecondaryInk : lightSecondaryInk
    }
}
