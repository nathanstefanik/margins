import MarginsModel
import SwiftUI

/// The reading surface's paper palette — a thin `Color` adapter over
/// `ReaderPalette`, which owns the values and stays mirrored by
/// `reader.html` / `reader.js`.
///
/// The chrome (sidebars, toolbars, panes) always uses system materials and
/// colors; the reading page is the single place with its own palette, which
/// the reader can flip between the light and dark papers.
enum Paper {
    static func background(_ theme: ReaderTheme) -> Color {
        Color(theme.palette.background)
    }

    static func ink(_ theme: ReaderTheme) -> Color {
        Color(theme.palette.ink)
    }

    static func secondaryInk(_ theme: ReaderTheme) -> Color {
        Color(theme.palette.secondaryInk)
    }
}

extension Color {
    /// A model-layer 0–255 RGB triple, straight through.
    init(_ rgb: ReaderPalette.RGB) {
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255)
    }
}
