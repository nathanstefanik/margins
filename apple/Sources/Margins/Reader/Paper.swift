import SwiftUI

/// The reading surface's fixed paper palette.
///
/// The chrome (sidebars, toolbars, panes) always uses system materials and
/// colors; the reading page is the single place with its own palette — the
/// cream paper theme hard-coded in `reader.html`. Keep both in sync.
enum Paper {
    /// Page background, matching reader.html's `#f4f1ea`.
    static let background = Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255)

    /// Body text ink, matching reader.html's `#111111`.
    static let ink = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)

    /// Muted ink for secondary text on paper (chapter title in the footer).
    static let secondaryInk = Color(red: 110 / 255, green: 104 / 255, blue: 94 / 255)
}
