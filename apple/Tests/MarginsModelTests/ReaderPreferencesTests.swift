import Testing
import Foundation
import MarginsModel

@Suite("ReaderPreferences")
@MainActor
struct ReaderPreferencesTests {
    private let suiteName = "ReaderPreferencesTests-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create UserDefaults suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("theme defaults to light and round-trips through the injected store")
    func themeRoundTripsThroughStore() {
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = makeDefaults()

        let first = ReaderPreferences(defaults: defaults)
        #expect(first.theme == ReaderTheme.light)

        first.theme = .dark
        let second = ReaderPreferences(defaults: defaults)
        #expect(second.theme == ReaderTheme.dark)
    }

    @Test("an unknown persisted theme falls back to light")
    func unknownPersistedThemeFallsBack() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set("sepia", forKey: "reader.theme")

        #expect(ReaderPreferences(defaults: defaults).theme == ReaderTheme.light)
    }

    @Test("preferences round-trip through the injected store")
    func roundTripsThroughStore() {
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = makeDefaults()

        let first = ReaderPreferences(defaults: defaults)
        first.stepFontSize(ReaderPreferences.fontSizeStep)
        first.stepFontSize(ReaderPreferences.fontSizeStep)
        first.lineHeight = 1.85
        first.lineWidth = 58

        let second = ReaderPreferences(defaults: defaults)
        #expect(second.fontSize == ReaderPreferences.defaultFontSize + 2 * ReaderPreferences.fontSizeStep)
        #expect(second.lineHeight == 1.85)
        #expect(second.lineWidth == 58)
    }

    @Test("font size steps clamp at the minimum and maximum")
    func fontSizeClamps() {
        let preferences = ReaderPreferences(defaults: makeDefaults())
        preferences.resetFontSize()

        preferences.stepFontSize(-1000)
        #expect(preferences.fontSize == ReaderPreferences.minFontSize)
        preferences.stepFontSize(-ReaderPreferences.fontSizeStep)
        #expect(preferences.fontSize == ReaderPreferences.minFontSize)

        preferences.stepFontSize(1000)
        #expect(preferences.fontSize == ReaderPreferences.maxFontSize)
        preferences.stepFontSize(ReaderPreferences.fontSizeStep)
        #expect(preferences.fontSize == ReaderPreferences.maxFontSize)
    }

    @Test("line height and line width clamp to their ranges")
    func lineHeightAndWidthClamp() {
        let preferences = ReaderPreferences(defaults: makeDefaults())

        preferences.lineHeight = 0
        #expect(preferences.lineHeight == ReaderPreferences.lineHeightRange.lowerBound)
        preferences.lineHeight = 99
        #expect(preferences.lineHeight == ReaderPreferences.lineHeightRange.upperBound)

        preferences.lineWidth = 0
        #expect(preferences.lineWidth == ReaderPreferences.lineWidthRange.lowerBound)
        preferences.lineWidth = 1000
        #expect(preferences.lineWidth == ReaderPreferences.lineWidthRange.upperBound)
    }

    @Test("reset restores defaults")
    func resetRestoresDefaults() {
        let preferences = ReaderPreferences(defaults: makeDefaults())
        preferences.fontSize = 190
        preferences.lineHeight = 2.0
        preferences.lineWidth = 100

        preferences.resetFontSize()
        #expect(preferences.fontSize == ReaderPreferences.defaultFontSize)

        preferences.resetTypography()
        #expect(preferences.fontSize == ReaderPreferences.defaultFontSize)
        #expect(preferences.lineHeight == ReaderPreferences.defaultLineHeight)
        #expect(preferences.lineWidth == ReaderPreferences.defaultLineWidth)
    }

    #if !os(iOS)
    @Test("page layout defaults to Automatic and round-trips")
    func pageLayoutRoundTrips() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.pageLayout == .automatic)

        preferences.pageLayout = .double
        #expect(ReaderPreferences(defaults: defaults).pageLayout == .double)
        preferences.pageLayout = .single
        #expect(ReaderPreferences(defaults: defaults).pageLayout == .single)
    }

    @Test("an unknown persisted page layout falls back to Automatic")
    func unknownPageLayoutFallsBack() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set("spread", forKey: "reader.pageLayout.macos")

        #expect(ReaderPreferences(defaults: defaults).pageLayout == .automatic)
    }

    @Test("resetTypography preserves the page-layout choice")
    func resetTypographyPreservesPageLayout() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        preferences.pageLayout = .double
        preferences.resetTypography()

        #expect(preferences.pageLayout == .double)
        #expect(ReaderPreferences(defaults: defaults).pageLayout == .double)
    }
    #endif

    @Test("out-of-range persisted values are clamped on load")
    func corruptPersistedValuesClampOnLoad() throws {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set(5000, forKey: "reader.fontSize")
        defaults.set(0, forKey: "reader.lineHeight")

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.fontSize == ReaderPreferences.maxFontSize)
        #expect(preferences.lineHeight == ReaderPreferences.lineHeightRange.lowerBound)
        #expect(preferences.lineWidth == ReaderPreferences.defaultLineWidth)
    }
}
