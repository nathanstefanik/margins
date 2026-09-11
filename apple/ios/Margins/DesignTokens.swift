import SwiftUI

/// The iOS app's shared design constants. Everything visual that is not a
/// system style lives here so the app stays coherent and easy to tune:
/// content is a plain canvas, controls float above it in one glass layer.
enum DesignTokens {
    /// Concentric rounding. The device corner is the outermost radius, so
    /// controls nested in a card use the smaller value and let the system
    /// keep their corners parallel to their container.
    enum Radius {
        static let cover: CGFloat = 10
        static let card: CGFloat = 20
        static let control: CGFloat = 14
    }

    enum Spacing {
        static let grid: CGFloat = 20
        static let gridCell: CGFloat = 16
        static let chrome: CGFloat = 10
    }

    enum Motion {
        static let chrome = Animation.easeOut(duration: 0.2)
        static let prompt = Animation.spring(response: 0.35, dampingFraction: 0.82)
    }

    /// The reader's paper, independent of the system appearance. Kept here
    /// so the page and the chrome that follows it agree on the palette.
    static let paper = Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255)
}
