import Foundation
import Observation

/// Reader typography preferences: text size, line width, and line height.
///
/// A chrome preference (window-level UI state), not library data, so it
/// persists via `UserDefaults` and stays out of the synced library tree.
/// Font size is a percentage applied on top of the book's base size
/// (100 = publisher default); line width is the centered text column's max
/// width in `ch` units; line height is a unitless multiplier.
@MainActor
@Observable
public final class ReaderPreferences {
    public static let minFontSize = 70.0
    public static let maxFontSize = 200.0
    public static let fontSizeStep = 10.0
    /// One step above the publisher default: on common laptop aspect ratios
    /// the column scales with font size, so this also widens the measure
    /// enough to keep the side margins modest.
    public static let defaultFontSize = 110.0
    public static let defaultLineHeight = 1.6
    public static let defaultLineWidth = 72.0

    public static let lineWidthRange = 50.0...110.0
    public static let lineHeightRange = 1.2...2.0

    private static let fontSizeKey = "reader.fontSize"
    private static let lineHeightKey = "reader.lineHeight"
    private static let lineWidthKey = "reader.lineWidth"

    private let defaults: UserDefaults
    // Backing storage for the clamped, persisting computed properties below.
    private var _fontSize: Double
    private var _lineHeight: Double
    private var _lineWidth: Double

    /// - Parameter defaults: injection point for tests; pass a
    ///   `UserDefaults(suiteName:)` to keep suites isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _fontSize = Self.clamp(
            defaults.object(forKey: Self.fontSizeKey) as? Double ?? Self.defaultFontSize,
            Self.minFontSize,
            Self.maxFontSize
        )
        _lineHeight = Self.clamp(
            defaults.object(forKey: Self.lineHeightKey) as? Double ?? Self.defaultLineHeight,
            Self.lineHeightRange.lowerBound,
            Self.lineHeightRange.upperBound
        )
        _lineWidth = Self.clamp(
            defaults.object(forKey: Self.lineWidthKey) as? Double ?? Self.defaultLineWidth,
            Self.lineWidthRange.lowerBound,
            Self.lineWidthRange.upperBound
        )
    }

    public var fontSize: Double {
        get { _fontSize }
        set {
            _fontSize = Self.clamp(newValue, Self.minFontSize, Self.maxFontSize)
            defaults.set(_fontSize, forKey: Self.fontSizeKey)
        }
    }

    public var lineHeight: Double {
        get { _lineHeight }
        set {
            _lineHeight = Self.clamp(
                newValue,
                Self.lineHeightRange.lowerBound,
                Self.lineHeightRange.upperBound
            )
            defaults.set(_lineHeight, forKey: Self.lineHeightKey)
        }
    }

    public var lineWidth: Double {
        get { _lineWidth }
        set {
            _lineWidth = Self.clamp(
                newValue,
                Self.lineWidthRange.lowerBound,
                Self.lineWidthRange.upperBound
            )
            defaults.set(_lineWidth, forKey: Self.lineWidthKey)
        }
    }

    /// Steps text size by `delta` percent, clamped to the allowed range.
    public func stepFontSize(_ delta: Double) {
        fontSize += delta
    }

    /// Restores the default text size (⌘0).
    public func resetFontSize() {
        fontSize = Self.defaultFontSize
    }

    /// Restores every typography preference to its default.
    public func resetTypography() {
        fontSize = Self.defaultFontSize
        lineHeight = Self.defaultLineHeight
        lineWidth = Self.defaultLineWidth
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
