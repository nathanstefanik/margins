import MarginsModel
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
        static let actions: CGFloat = 12
        static let controlInset: CGFloat = 12
        static let readerHeaderLift: CGFloat = 10
    }

    enum Control {
        static let minimumTarget: CGFloat = 44
        static let readerTarget: CGFloat = 48
        static let fontSizeLabelHeight: CGFloat = 36
    }

    enum Motion {
        static let chrome = Animation.easeOut(duration: 0.2)
        static let prompt = Animation.spring(response: 0.35, dampingFraction: 0.82)
        static let flashIn = Animation.easeOut(duration: 0.25)
        static let flashOut = Animation.easeInOut(duration: 0.6)
    }

    /// The reader's paper — a thin `Color` adapter over `ReaderPalette`,
    /// which owns the values mirrored by `reader.html` / `reader.js`. The
    /// reading surface is the single place with its own palette; chrome
    /// and sheets follow the system appearance.
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
