import Foundation
import MarginsModel
import Testing

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
        defaults.set("beige", forKey: "reader.theme")

        #expect(ReaderPreferences(defaults: defaults).theme == ReaderTheme.light)
    }

    @Test("a fresh install follows the system appearance")
    func freshInstallFollowsSystem() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.followsSystem)
        #expect(preferences.dayTheme == .light)
        #expect(preferences.nightTheme == .dark)
        #expect(preferences.theme == .light)

        preferences.systemIsDark = true
        #expect(preferences.theme == .dark)
    }

    @Test("a stored theme keeps the fixed paper and stops following")
    func storedThemeStaysFixed() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set("dark", forKey: "reader.theme")

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(!preferences.followsSystem)
        #expect(preferences.theme == .dark)

        preferences.systemIsDark = false
        #expect(preferences.theme == .dark)
    }

    @Test("following resolves the day or night paper per system appearance")
    func followResolutionMatrix() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        preferences.dayTheme = .sepia
        preferences.nightTheme = .night

        preferences.followsSystem = true
        preferences.systemIsDark = false
        #expect(preferences.theme == .sepia)
        preferences.systemIsDark = true
        #expect(preferences.theme == .night)

        preferences.followsSystem = false
        preferences.theme = .light
        preferences.systemIsDark = true
        #expect(preferences.theme == .light)
        preferences.systemIsDark = false
        #expect(preferences.theme == .light)
    }

    @Test("the follow-system keys round-trip through the injected store")
    func followKeysRoundTrip() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        preferences.followsSystem = false
        preferences.dayTheme = .sepia
        preferences.nightTheme = .night

        let second = ReaderPreferences(defaults: defaults)
        #expect(!second.followsSystem)
        #expect(second.dayTheme == .sepia)
        #expect(second.nightTheme == .night)
    }

    @Test("foreign papers stored in the day/night keys fall back per side")
    func foreignDayNightValuesFallBack() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set("night", forKey: "reader.theme.day")
        defaults.set("light", forKey: "reader.theme.night")

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.dayTheme == .light)
        #expect(preferences.nightTheme == .dark)
    }

    @Test("the day and night setters refuse papers from the other side")
    func dayNightSettersGuard() {
        let preferences = ReaderPreferences(defaults: makeDefaults())
        preferences.dayTheme = .night
        preferences.nightTheme = .light
        #expect(preferences.dayTheme == .light)
        #expect(preferences.nightTheme == .dark)
    }

    @Test("justify defaults off, ornaments on; both round-trip")
    func proseOptionsRoundTrip() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.justify == false)
        #expect(preferences.ornaments == true)

        preferences.justify = true
        preferences.ornaments = false
        let second = ReaderPreferences(defaults: defaults)
        #expect(second.justify == true)
        #expect(second.ornaments == false)
    }

    @Test("reset restores prose defaults")
    func resetRestoresProseDefaults() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        preferences.justify = true
        preferences.ornaments = false
        preferences.resetTypography()
        #expect(preferences.justify == false)
        #expect(preferences.ornaments == true)
    }

    @Test("setting the resolved theme picks a fixed paper and unfollows")
    func themeSetterUnfollows() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.followsSystem)

        preferences.theme = .sepia
        #expect(!preferences.followsSystem)
        #expect(preferences.theme == .sepia)
        #expect(defaults.string(forKey: "reader.theme") == "sepia")
        #expect(defaults.object(forKey: "reader.theme.followsSystem") as? Bool == false)

        #expect(ReaderPreferences(defaults: defaults).theme == .sepia)
    }

    @Test("typeface defaults to serif and round-trips every face through the store")
    func typefaceRoundTripsThroughStore() {
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = makeDefaults()

        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.typeface == .serif)

        for face in ReaderTypeface.allCases {
            preferences.typeface = face
            #expect(ReaderPreferences(defaults: defaults).typeface == face)
        }
    }

    @Test("an unknown persisted typeface falls back to serif")
    func unknownPersistedTypefaceFallsBack() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set("comic", forKey: "reader.typeface")

        #expect(ReaderPreferences(defaults: defaults).typeface == .serif)
    }

    @Test("a stored sans preference resolves to the sans face")
    func storedSansResolvesToSans() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set("sans", forKey: "reader.typeface")

        #expect(ReaderPreferences(defaults: defaults).typeface == .sans)
    }

    @Test("each typeface names the family the reader resolves")
    func typefaceFamilyNames() {
        #expect(ReaderTypeface.serif.familyName == "Charter")
        #expect(ReaderTypeface.sans.familyName == "Seravek")
        #expect(ReaderTypeface.easy.familyName == "Atkinson Hyperlegible Next")
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
        preferences.typeface = .easy

        preferences.resetFontSize()
        #expect(preferences.fontSize == ReaderPreferences.defaultFontSize)
        #expect(preferences.typeface == .easy)

        preferences.resetTypography()
        #expect(preferences.fontSize == ReaderPreferences.defaultFontSize)
        #expect(preferences.lineHeight == ReaderPreferences.defaultLineHeight)
        #expect(preferences.lineWidth == ReaderPreferences.defaultLineWidth)
        #expect(preferences.typeface == ReaderPreferences.defaultTypeface)
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

    @Test("the text-size step controls disable at the bounds")
    func fontSizeStepControlsDisableAtBounds() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let preferences = ReaderPreferences(defaults: defaults)

        #expect(preferences.canStepFontSmaller)
        #expect(preferences.canStepFontLarger)

        preferences.fontSize = ReaderPreferences.maxFontSize
        #expect(!preferences.canStepFontLarger)
        #expect(preferences.canStepFontSmaller)

        preferences.fontSize = ReaderPreferences.minFontSize
        #expect(!preferences.canStepFontSmaller)
        #expect(preferences.canStepFontLarger)
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

        // A size persisted under the old 70 % floor clamps up to the new
        // minimum — no migration, just the load clamp.
        defaults.set(70, forKey: "reader.fontSize")
        #expect(ReaderPreferences(defaults: defaults).fontSize == ReaderPreferences.minFontSize)
    }
}
