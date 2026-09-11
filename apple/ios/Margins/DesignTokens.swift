import SwiftUI
import MarginsModel

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

    /// The reader's paper, mirroring the palettes in `reader.html` /
    /// `reader.js`. The reading surface is the single place with its own
    /// palette; chrome and sheets follow the system appearance.
    enum Paper {
        static let lightBackground = Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255)
        static let lightSecondaryInk = Color(red: 110 / 255, green: 104 / 255, blue: 94 / 255)

        static let darkBackground = Color(red: 27 / 255, green: 26 / 255, blue: 24 / 255)
        static let darkSecondaryInk = Color(red: 168 / 255, green: 161 / 255, blue: 150 / 255)

        static func background(_ theme: ReaderTheme) -> Color {
            theme == .dark ? darkBackground : lightBackground
        }

        static func secondaryInk(_ theme: ReaderTheme) -> Color {
            theme == .dark ? darkSecondaryInk : lightSecondaryInk
        }
    }
}
