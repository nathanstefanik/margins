import Foundation
import Observation

/// The reading surface's palette. The resolved value every consumer reads
/// — `Paper`, the webview bridge, and reader.js get a concrete paper out
/// of it regardless of whether the user picked a fixed theme or follows
/// the system appearance.
public enum ReaderTheme: String, CaseIterable, Sendable {
    case light
    case sepia
    case dark
    case night

    /// The name the pickers and accessibility labels show.
    public var name: String {
        switch self {
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        case .night: "Night"
        }
    }

    /// Light papers the day preference accepts; the night preference
    /// accepts the dark pair.
    public var isDayPaper: Bool { !palette.isDark }

    /// The light pair, in swatch order.
    public static var dayPapers: [ReaderTheme] {
        allCases.filter(\.isDayPaper)
    }

    /// The dark pair, in swatch order.
    public static var nightPapers: [ReaderTheme] {
        allCases.filter { !$0.isDayPaper }
    }
}

/// The reader's three faces on both platforms. Charter and Seravek ship
/// with macOS and iOS; Easy is Atkinson Hyperlegible Next — bundled in the
/// reader resources, served to the webview over `margins-reader://`, and
/// carrying fixed extra letter/word spacing and line height for low-vision
/// readers (not user-configurable). Stored "sans" values from earlier
/// versions now resolve to Seravek — intended.
public enum ReaderTypeface: String, CaseIterable, Sendable {
    case serif
    case sans
    case easy

    /// The family the face resolves to — the Swift-side single source of
    /// truth (the iOS chrome uses it; reader.js mirrors it in its stacks).
    public var familyName: String {
        switch self {
        case .serif: "Charter"
        case .sans: "Seravek"
        case .easy: "Atkinson Hyperlegible Next"
        }
    }
}

/// What the page indicator shows while reading: the chapter-local page
/// count, an estimate from the reader's own pace, or nothing.
public enum ReaderPageIndicator: String, CaseIterable, Sendable {
    case pages
    case timeLeft
    case none

    /// The name the pickers and accessibility labels show.
    public var name: String {
        switch self {
        case .pages: "Pages"
        case .timeLeft: "Time left"
        case .none: "None"
        }
    }
}

#if !os(iOS)
/// macOS page layout: let the reading viewport decide, or pin one or two
/// pages. The web reader resolves the effective layout from the actual
/// available width and text size; this preference only states intent.
/// Unknown stored values fall back to `automatic`.
public enum ReaderPageLayout: String, CaseIterable, Sendable {
    case automatic
    case single
    case double
}
#endif

/// Reader typography and theme preferences.
///
/// Chrome preferences (window-level UI state), not library data, so they
/// persist via `UserDefaults` and stay out of the synced library tree.
///
/// Per platform:
/// - macOS keeps the percentage API: font size is a percentage applied on
///   top of the book's base size (100 = publisher default), line width is
///   the centered text column's max width in `ch` units, line height is a
///   unitless multiplier.
/// - iOS drives the reader through `fontStep` (1…6) instead: a short
///   internal ladder mapped to px at apply time. The UI exposes only
///   smaller/larger "A" buttons; the numbers never reach the reader.
@MainActor
@Observable
public final class ReaderPreferences {
    /// Cream paper is the reader's native look; the app chrome follows the
    /// system appearance instead.
    public static let defaultTheme = ReaderTheme.light
    /// The papers `followsSystem` falls back to per side of the system
    /// appearance and the default for each stored key.
    public static let defaultDayTheme = ReaderTheme.light
    public static let defaultNightTheme = ReaderTheme.dark
    /// Serif by default: the printed-spread reading face.
    public static let defaultTypeface = ReaderTypeface.serif

    /// Flush-left is the default read; justification is opt-in.
    public static let defaultJustify = false
    /// Drop cap and small caps at chapter openings; off means plain.
    public static let defaultOrnaments = true

    /// The default page indicator: the plain page count.
    public static let defaultPageIndicator = ReaderPageIndicator.pages
    public static let defaultPauseAtChapterEnds = true

    private static let themeKey = "reader.theme"
    private static let followsSystemKey = "reader.theme.followsSystem"
    private static let dayThemeKey = "reader.theme.day"
    private static let nightThemeKey = "reader.theme.night"
    private static let typefaceKey = "reader.typeface"
    private static let justifyKey = "reader.justify"
    private static let ornamentsKey = "reader.ornaments"
    private static let pageIndicatorKey = "reader.pageIndicator"
    private static let hideSidebarKey = "reader.hideSidebarWhileReading"
    private static let chapterEndPauseKey = "reader.chapterEndPause"

    private let defaults: UserDefaults
    private var _fixedTheme: ReaderTheme
    private var _followsSystem: Bool
    private var _dayTheme: ReaderTheme
    private var _nightTheme: ReaderTheme
    private var _typeface: ReaderTypeface
    private var _justify: Bool
    private var _ornaments: Bool
    private var _pageIndicator: ReaderPageIndicator
    private var _hideSidebarWhileReading: Bool
    private var _pauseAtChapterEnds: Bool

    /// - Parameter defaults: injection point for tests; pass a
    ///   `UserDefaults(suiteName:)` to keep suites isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTheme = defaults.string(forKey: Self.themeKey)
        _fixedTheme =
            storedTheme.flatMap(ReaderTheme.init(rawValue:)) ?? Self.defaultTheme
        // Fresh installs follow the system; a stored `reader.theme` means
        // the user already picked a paper, so they keep it.
        _followsSystem =
            defaults.object(forKey: Self.followsSystemKey) as? Bool
            ?? (storedTheme == nil)
        // The day/night slots only accept their side of the palette; a
        // foreign or unknown stored value resets to that side's default.
        _dayTheme =
            ReaderTheme(rawValue: defaults.string(forKey: Self.dayThemeKey) ?? "")
            .flatMap { $0.isDayPaper ? $0 : nil } ?? Self.defaultDayTheme
        _nightTheme =
            ReaderTheme(rawValue: defaults.string(forKey: Self.nightThemeKey) ?? "")
            .flatMap { $0.isDayPaper ? nil : $0 } ?? Self.defaultNightTheme
        _typeface = Self.typeface(from: defaults.string(forKey: Self.typefaceKey))
        _justify = defaults.bool(forKey: Self.justifyKey)
        _ornaments =
            defaults.object(forKey: Self.ornamentsKey) as? Bool ?? Self.defaultOrnaments
        _pageIndicator =
            ReaderPageIndicator(rawValue: defaults.string(forKey: Self.pageIndicatorKey) ?? "")
            ?? Self.defaultPageIndicator
        _hideSidebarWhileReading = defaults.bool(forKey: Self.hideSidebarKey)
        _pauseAtChapterEnds =
            defaults.object(forKey: Self.chapterEndPauseKey) as? Bool
            ?? Self.defaultPauseAtChapterEnds

        #if os(iOS)
        var storedStep = defaults.integer(forKey: Self.fontStepKey)
        // Re-anchor a step saved on an older ladder so the reader's text
        // size does not silently shrink when a smaller rung is added.
        if storedStep > 0,
            defaults.integer(forKey: Self.fontLadderVersionKey) < Self.fontLadderVersion
        {
            storedStep += 1
        }
        _fontStep =
            (1...Self.fontStepsPx.count).contains(storedStep)
            ? storedStep
            : Self.defaultFontStep
        defaults.set(Self.fontLadderVersion, forKey: Self.fontLadderVersionKey)
        #else
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
        _pageLayout =
            ReaderPageLayout(rawValue: defaults.string(forKey: Self.pageLayoutKey) ?? "")
            ?? .automatic
        #endif
    }

    /// The resolved paper everyone reads. With `followsSystem` on it
    /// answers the day/night choice for the current system appearance;
    /// setting it picks a fixed paper and turns following off, so the old
    /// direct-pick call sites behave as they always did.
    public var theme: ReaderTheme {
        get { _followsSystem ? (systemIsDark ? _nightTheme : _dayTheme) : _fixedTheme }
        set {
            _fixedTheme = newValue
            _followsSystem = false
            defaults.set(newValue.rawValue, forKey: Self.themeKey)
            defaults.set(false, forKey: Self.followsSystemKey)
        }
    }

    /// Whether the paper follows the system appearance. Defaults to true
    /// on a fresh install and to false when a stored `reader.theme` says
    /// the user already chose one.
    public var followsSystem: Bool {
        get { _followsSystem }
        set {
            _followsSystem = newValue
            defaults.set(newValue, forKey: Self.followsSystemKey)
        }
    }

    /// The paper used while the system is light and `followsSystem` is
    /// on. Only the light papers are accepted.
    public var dayTheme: ReaderTheme {
        get { _dayTheme }
        set {
            guard newValue.isDayPaper else { return }
            _dayTheme = newValue
            defaults.set(newValue.rawValue, forKey: Self.dayThemeKey)
        }
    }

    /// The paper used while the system is dark and `followsSystem` is
    /// on. Only the dark papers are accepted.
    public var nightTheme: ReaderTheme {
        get { _nightTheme }
        set {
            guard !newValue.isDayPaper else { return }
            _nightTheme = newValue
            defaults.set(newValue.rawValue, forKey: Self.nightThemeKey)
        }
    }

    /// The current system appearance, pushed in by each app's root view
    /// (`@Environment(\.colorScheme)`). Not persisted.
    public var systemIsDark = false

    /// Justified body text with hyphenation. The Easy face ignores it —
    /// its spacing is the point.
    public var justify: Bool {
        get { _justify }
        set {
            _justify = newValue
            defaults.set(newValue, forKey: Self.justifyKey)
        }
    }

    /// Drop cap and small caps on the paragraph opening a chapter.
    public var ornaments: Bool {
        get { _ornaments }
        set {
            _ornaments = newValue
            defaults.set(newValue, forKey: Self.ornamentsKey)
        }
    }

    /// The page indicator mode the footers show. Not part of macOS's
    /// Reset Typography — it is display chrome, not typography.
    public var pageIndicator: ReaderPageIndicator {
        get { _pageIndicator }
        set {
            _pageIndicator = newValue
            defaults.set(newValue.rawValue, forKey: Self.pageIndicatorKey)
        }
    }

    /// macOS: collapse the library sidebar for the duration of a reading
    /// session, restoring the previous split state on close. Off by
    /// default. The sidebar stays collapsed while either focus mode or
    /// this setting applies and restores when neither does.
    public var hideSidebarWhileReading: Bool {
        get { _hideSidebarWhileReading }
        set {
            _hideSidebarWhileReading = newValue
            defaults.set(newValue, forKey: Self.hideSidebarKey)
        }
    }

    /// Pause on the chapter-end page when a forward turn runs past a
    /// chapter's last page into its successor.
    public var pauseAtChapterEnds: Bool {
        get { _pauseAtChapterEnds }
        set {
            _pauseAtChapterEnds = newValue
            defaults.set(newValue, forKey: Self.chapterEndPauseKey)
        }
    }

    // MARK: Chapter-end page silences

    /// `notePrompt.dismissed.<bookId>.<chapterKey>` — the original iOS
    /// prompt's silence key, kept so already-dismissed chapters stay
    /// silent. Marked when the page is *shown*: each chapter pauses once.
    private static func chapterEndSilenceKey(bookId: String, chapterKey: String) -> String {
        "notePrompt.dismissed.\(bookId).\(chapterKey)"
    }

    public func chapterEndPageSilenced(bookId: String, chapterKey: String) -> Bool {
        defaults.bool(forKey: Self.chapterEndSilenceKey(bookId: bookId, chapterKey: chapterKey))
    }

    /// Marks the chapter's end page as shown (or dismissed) — it will not
    /// pause again.
    public func silenceChapterEndPage(bookId: String, chapterKey: String) {
        defaults.set(
            true, forKey: Self.chapterEndSilenceKey(bookId: bookId, chapterKey: chapterKey))
    }

    /// The fingerprint the pace meter keys on: anything that changes how
    /// many words land on a page. Both platforms' knobs are included so
    /// the key only differs when the effective layout differs.
    public var typographyKey: String {
        var parts = [
            "face=\(_typeface.rawValue)",
            "justify=\(_justify)",
            "ornaments=\(_ornaments)",
        ]
        #if os(iOS)
        parts.append("step=\(_fontStep)")
        #else
        parts.append("size=\(_fontSize)")
        parts.append("lh=\(_lineHeight)")
        parts.append("lw=\(_lineWidth)")
        parts.append("layout=\(_pageLayout.rawValue)")
        #endif
        return parts.joined(separator: "|")
    }

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

    private static let fontStepKey = "reader.fontStep"
    private static let fontLadderVersionKey = "reader.fontStep.ladderVersion"

    /// Bumped whenever `fontStepsPx` gains or loses a rung. v1 began at
    /// 14px; v2 added 12px at the bottom, shifting every index up by one.
    private static let fontLadderVersion = 2

    private var _fontStep: Int

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
    #else
    public static let minFontSize = 80.0
    public static let maxFontSize = 210.0
    public static let fontSizeStep = 10.0
    /// Two steps above the publisher default: on common laptop aspect
    /// ratios the column scales with font size, so this also widens the
    /// measure enough to keep the side margins modest.
    public static let defaultFontSize = 120.0
    public static let defaultLineHeight = 1.6
    public static let defaultLineWidth = 72.0

    public static let lineWidthRange = 50.0...110.0
    public static let lineHeightRange = 1.2...2.0

    private static let fontSizeKey = "reader.fontSize"
    private static let lineHeightKey = "reader.lineHeight"
    private static let lineWidthKey = "reader.lineWidth"
    /// macOS-only and platform-namespaced: the iOS reader has no page
    /// layout control, and a future iOS default must not inherit this.
    private static let pageLayoutKey = "reader.pageLayout.macos"

    // Backing storage for the clamped, persisting computed properties below.
    private var _fontSize: Double
    private var _lineHeight: Double
    private var _lineWidth: Double
    private var _pageLayout: ReaderPageLayout

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

    /// The requested page layout. Kept separate from Reset Typography:
    /// text size, height, and width are typography; how many pages share
    /// the window is a layout choice the reader may override per width.
    public var pageLayout: ReaderPageLayout {
        get { _pageLayout }
        set {
            _pageLayout = newValue
            defaults.set(newValue.rawValue, forKey: Self.pageLayoutKey)
        }
    }

    /// At the bottom of the range: the smaller-A control disables.
    public var canStepFontSmaller: Bool { fontSize > Self.minFontSize }

    /// At the top of the range: the larger-A control disables.
    public var canStepFontLarger: Bool { fontSize < Self.maxFontSize }

    /// Steps text size by `delta` percent, clamped to the allowed range.
    public func stepFontSize(_ delta: Double) {
        fontSize += delta
    }

    /// Restores the default text size (⌘0).
    public func resetFontSize() {
        fontSize = Self.defaultFontSize
    }

    /// Restores every typography preference to its default. Page layout is
    /// deliberately excluded — it is a layout choice, not typography.
    public func resetTypography() {
        fontSize = Self.defaultFontSize
        lineHeight = Self.defaultLineHeight
        lineWidth = Self.defaultLineWidth
        typeface = Self.defaultTypeface
        justify = Self.defaultJustify
        ornaments = Self.defaultOrnaments
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
    #endif
}
