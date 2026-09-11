import Foundation
import Observation

#if os(iOS)
/// The reader's two faces: system serif (New York) and system sans
/// (SF Pro). Both resolve on-device in the webview via generic families
/// (`ui-serif` / `-apple-system`) — no files bundled, zero MB, and the
/// sanctioned production path to New York.
public enum ReaderTypeface: String, CaseIterable, Sendable {
    case serif
    case sans
}
#endif

/// Reader typography preferences.
///
/// A chrome preference (window-level UI state), not library data, so it
/// persists via `UserDefaults` and stays out of the synced library tree.
///
/// Per platform:
/// - macOS keeps the percentage API: font size is a percentage applied on
///   top of the book's base size (100 = publisher default), line width is
///   the centered text column's max width in `ch` units, line height is a
///   unitless multiplier.
/// - iOS drives the reader through `fontStep` (1…5) instead: a short
///   internal ladder mapped to px at apply time. The UI exposes only
///   smaller/larger "A" buttons; the numbers never reach the reader.
@MainActor
@Observable
public final class ReaderPreferences {
    #if os(iOS)
    /// The text ladder behind the smaller/larger controls, in px applied
    /// to the rendition. Deliberately short: six steps cover phone
    /// reading without a slider, with 12px for dense small-print passages.
    public static let fontStepsPx: [Double] = [12.0, 14.0, 16.0, 18.0, 21.0, 24.0]
    /// The 18px rung — readable body text at a phone measure. Bumped from
    /// 3 to 4 when 12px was added at the bottom of the ladder, so the
    /// default reading size is unchanged.
    public static let defaultFontStep = 4
    /// Fixed line height for the iOS reader (not configurable).
    public static let iosLineHeight = 1.65
    /// Serif by default: the printed-spread reading face.
    public static let defaultTypeface = ReaderTypeface.serif

    private static let fontStepKey = "reader.fontStep"
    private static let fontLadderVersionKey = "reader.fontStep.ladderVersion"
    private static let typefaceKey = "reader.typeface"

    /// Bumped whenever `fontStepsPx` gains or loses a rung. v1 began at
    /// 14px; v2 added 12px at the bottom, shifting every index up by one.
    private static let fontLadderVersion = 2

    private let defaults: UserDefaults
    private var _fontStep: Int
    private var _typeface: ReaderTypeface

    /// - Parameter defaults: injection point for tests; pass a
    ///   `UserDefaults(suiteName:)` to keep suites isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var storedStep = defaults.integer(forKey: Self.fontStepKey)
        // Re-anchor a step saved on an older ladder so the reader's text
        // size does not silently shrink when a smaller rung is added.
        if storedStep > 0,
           defaults.integer(forKey: Self.fontLadderVersionKey) < Self.fontLadderVersion {
            storedStep += 1
        }
        _fontStep = (1...Self.fontStepsPx.count).contains(storedStep)
            ? storedStep
            : Self.defaultFontStep
        defaults.set(Self.fontLadderVersion, forKey: Self.fontLadderVersionKey)
        _typeface = Self.typeface(from: defaults.string(forKey: Self.typefaceKey))
    }

    /// Current rung of the text ladder (1-based). The numbers are internal;
    /// the UI only steps up and down.
    public var fontStep: Int {
        get { _fontStep }
        set {
            _fontStep = min(max(newValue, 1), Self.fontStepsPx.count)
            defaults.set(_fontStep, forKey: Self.fontStepKey)
        }
    }

    /// The px size handed to the rendition for the current step.
    public var fontSizePx: Double {
        Self.fontStepsPx[_fontStep - 1]
    }

    /// Steps the text ladder up/down, clamped at the ends.
    public func stepFont(_ delta: Int) {
        fontStep = _fontStep + delta
    }

    /// At the bottom of the ladder: the smaller-A control disables.
    public var canStepFontSmaller: Bool { _fontStep > 1 }

    /// At the top of the ladder: the larger-A control disables.
    public var canStepFontLarger: Bool { _fontStep < Self.fontStepsPx.count }

    /// The chosen face. The whole book follows it (publisher families are
    /// forced to inherit; code/pre keep their monospace).
    public var typeface: ReaderTypeface {
        get { _typeface }
        set {
            _typeface = newValue
            defaults.set(newValue.rawValue, forKey: Self.typefaceKey)
        }
    }

    private static func typeface(from raw: String?) -> ReaderTypeface {
        raw.flatMap(ReaderTypeface.init(rawValue:)) ?? Self.defaultTypeface
    }
    #else
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
    #endif
}
