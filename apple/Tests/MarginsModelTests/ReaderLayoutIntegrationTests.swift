#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import MarginsModel

/// Reader-page acceptance cases driven through the real vendored renderer
/// in a WKWebView. Serialized: each case starts a WebKit content process.
@Suite("Reader layout integration", .serialized)
@MainActor
struct ReaderLayoutIntegrationTests {
    private func makeHarness(
        _ fixture: ReaderLayoutFixture = .reflowable,
        width: Double = 900,
        height: Double = 700
    ) throws -> ReaderLayoutHarness {
        try ReaderLayoutHarness(fixture: fixture, viewport: CGSize(width: width, height: height))
    }

    private func jsLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: Opening and navigation

    @Test("the reflowable fixture opens and reports a settled relocation")
    func reflowableFixtureOpens() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()

        let relocation = try await harness.waitForMessage(
            "relocated",
            matching: { $0["cfi"] as? String != nil },
            "the first relocation"
        )
        #expect((relocation["href"] as? String)?.hasSuffix("ch1.xhtml") == true)
        #expect((relocation["cfi"] as? String)?.isEmpty == false)
        #expect(relocation["page"] as? Int == 1)
        #expect((relocation["totalPages"] as? Int ?? 0) > 0)
        #expect(try await harness.visibleParagraphIDs().isEmpty == false)
    }

    @Test("next and previous page through the fixture and back")
    func nextAndPreviousMoveThePage() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        let first = try await harness.waitForRelocation(after: 0)
        let firstCfi = first["cfi"] as? String

        try await harness.evaluate("readerScrollBy(1)")
        let second = try await harness.waitForRelocationChange(from: first)
        #expect(second["cfi"] as? String != firstCfi)

        try await harness.evaluate("readerScrollBy(-1)")
        let back = try await harness.waitForRelocationChange(from: second)
        #expect(back["cfi"] as? String == firstCfi)
    }

    @Test("a saved CFI reopens the same passage")
    func cfiNavigationKeepsThePassageVisible() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        let opened = try await harness.waitForRelocation(after: 0)

        try await harness.evaluate("readerScrollBy(1)")
        let second = try await harness.waitForRelocationChange(from: opened)
        let cfi = try #require(second["cfi"] as? String)
        let visible = try await harness.visibleParagraphIDs()
        #expect(visible.isEmpty == false)

        // A fresh page opened at that CFI must show one of the paragraphs
        // that were visible when the CFI was captured.
        let reopened = try makeHarness(width: 900, height: 700)
        defer { reopened.dismantle() }
        try await reopened.load()
        try await reopened.waitForRelocation(after: 0)
        try await reopened.evaluate("readerDisplay(\(jsLiteral(cfi)))")
        let settled = try await reopened.waitForMessage(
            "relocated",
            matching: { $0["cfi"] as? String == cfi },
            "the requested CFI to settle"
        )
        #expect(settled["cfi"] as? String == cfi)

        let reopenedVisible = try await reopened.visibleParagraphIDs()
        #expect(Set(visible).intersection(reopenedVisible).isEmpty == false)
    }

    // MARK: Pure layout policy (the numeric contract)

    @Test("the pure resolver implements the documented policy cases")
    func pureResolverContract() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)

        let cases: [(String, Int)] = [
            ("{mode:'automatic',widthPx:1016,glyphWidthPx:8,lineWidthCh:72,previousPages:1}", 2),
            ("{mode:'automatic',widthPx:983,glyphWidthPx:8,lineWidthCh:72,previousPages:2}", 1),
            ("{mode:'single',widthPx:1400,glyphWidthPx:8,lineWidthCh:72,previousPages:1}", 1),
            ("{mode:'double',widthPx:728,glyphWidthPx:8,lineWidthCh:72,previousPages:1}", 2),
            ("{mode:'double',widthPx:727,glyphWidthPx:8,lineWidthCh:72,previousPages:1}", 1),
        ]
        for (options, expected) in cases {
            let pages = try await harness.evaluate(
                "window.readerResolveLayout(\(options)).pages"
            ) as? Int
            #expect(pages == expected, "policy case \(options)")
        }
        // The viewer cap keeps the selected measure: single page = 48 +
        // lineWidthCh * glyph; two pages add the gutter and a second page.
        let singleWidth = try await harness.evaluate(
            "window.readerResolveLayout({mode:'single',widthPx:1400,glyphWidthPx:8,lineWidthCh:72}).viewerWidthPx"
        ) as? Double
        #expect(singleWidth == 624)
        let doubleWidth = try await harness.evaluate(
            "window.readerResolveLayout({mode:'double',widthPx:1400,glyphWidthPx:8,lineWidthCh:72}).viewerWidthPx"
        ) as? Double
        #expect(doubleWidth == 1240)
    }

    // MARK: Adaptive geometry

    @Test("narrow Automatic renders one column and wide Automatic two")
    func automaticRespondsToWidth() async throws {
        let harness = try makeHarness(width: 600, height: 650)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)

        let narrow = try await harness.waitForDivisor(1)
        // One page: the measure spans the stage minus epub.js's gap/2 body
        // padding on each side.
        let narrowRects = try await harness.visibleParagraphRects()
        let narrowMeasure = try #require(narrowRects.first?.width)
        #expect(abs(narrowMeasure - (narrow.stageWidth - 40)) < 1)

        try await harness.resize(to: CGSize(width: 1400, height: 800))
        let wide = try await harness.waitForDivisor(2)
        // Two pages: each measure is half the stage after the outer body
        // padding and the fixed 40 px gutter.
        #expect(abs(wide.gap - 40) < 1)
        let wideRects = try await harness.visibleParagraphRects()
        #expect(wideRects.count >= 2)
        let widest = try #require(wideRects.map(\.width).max())
        #expect(abs(widest - (wide.stageWidth - 80) / 2) < 1)
        // Pages fill the whole viewer minus the outer insets.
        #expect(abs(wide.stageWidth - (wide.viewerWidth - 2 * wide.viewerPaddingLeft)) < 1)
        // Both columns sit inside the centered viewer's content box.
        let viewerLeft = (wide.innerWidth - wide.viewerWidth) / 2
        let lefts = wideRects.map(\.left)
        let rights = wideRects.map(\.right)
        #expect((lefts.min() ?? 0) >= viewerLeft + wide.viewerPaddingLeft - 1)
        #expect((rights.max() ?? 0) <= viewerLeft + wide.viewerWidth - wide.viewerPaddingLeft + 2)
    }

    @Test("One Page stays single and centered even in a wide viewport")
    func singleModeStaysSingle() async throws {
        let harness = try makeHarness(width: 1400, height: 800)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)

        try await harness.evaluate("readerSetPageLayout('single')")
        let geometry = try await harness.waitForDivisor(1)
        // Centered: equal space on both sides.
        let margins = try await harness.evaluate(
            "window.innerWidth - document.getElementById('viewer').getBoundingClientRect().right"
        ) as? Double
        let left = try await harness.evaluate(
            "document.getElementById('viewer').getBoundingClientRect().left"
        ) as? Double
        #expect(abs((margins ?? 0) - (left ?? 0)) < 1)
        #expect(geometry.viewerWidth < geometry.innerWidth)
        let rects = try await harness.visibleParagraphRects()
        let measure = try #require(rects.first?.width)
        #expect(abs(measure - (geometry.stageWidth - 40)) < 1)
    }

    @Test("Two Pages falls back to one when the measure cannot fit")
    func doubleModeFallsBack() async throws {
        let harness = try makeHarness(width: 600, height: 650)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)

        try await harness.evaluate("readerSetPageLayout('double')")
        let narrow = try await harness.waitForDivisor(1)
        #expect(narrow.renderedDivisor == 1)

        try await harness.resize(to: CGSize(width: 1000, height: 700))
        let wide = try await harness.waitForDivisor(2)
        #expect(wide.gap == 40)
    }

    @Test("a larger body font can force Automatic back to one page")
    func largeTextTriggersFallback() async throws {
        let harness = try makeHarness(width: 1440, height: 820)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(2)

        try await harness.evaluate("readerApplyTypography(200,1.6,72,'%')")
        _ = try await harness.waitForDivisor(1)

        // Back to the default size: the wider viewport fits two pages again.
        try await harness.evaluate("readerApplyTypography(110,1.6,72,'%')")
        _ = try await harness.waitForDivisor(2)
    }

    @Test("Automatic uses hysteresis around the fit threshold")
    func automaticHysteresis() async throws {
        let harness = try makeHarness(width: 1400, height: 820)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(2)

        let glyph = try await glyphWidth(harness)
        let lineWidthCh = try await advertisedLineWidth(harness)
        let measure = min(lineWidthCh, 56)
        let fit = (48 + 40 + 2 * measure * glyph).rounded(.down)

        // Just below the fit threshold after two pages: leave to one.
        try await harness.resize(to: CGSize(width: fit - 2, height: 700))
        _ = try await harness.waitForDivisor(1)

        // Eight px above the fit threshold, but not 32 above: stay single.
        // The engine's own 50 ms resize handler can transiently re-split
        // before the policy pins spread "none", so assert after it settles.
        try await harness.resize(to: CGSize(width: fit + 8, height: 700))
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await harness.geometry().renderedDivisor == 1)

        // Another 40 px up puts it past the hysteresis threshold: two.
        try await harness.resize(to: CGSize(width: fit + 48, height: 700))
        _ = try await harness.waitForDivisor(2)
    }

    @Test("fixed-layout and RTL content fall back to a single page")
    func unsupportedContentStaysSingle() async throws {
        for (fixture, chapter) in [
            (ReaderLayoutFixture.fixedLayout, "page1.xhtml"),
            (ReaderLayoutFixture.rtl, "ch1.xhtml"),
        ] {
            let harness = try makeHarness(fixture, width: 1440, height: 820)
            defer { harness.dismantle() }
            try await harness.load(chapter: chapter)
            _ = try await harness.waitForRelocation(after: 0)
            let geometry = try await harness.waitForDivisor(1)
            #expect(geometry.renderedDivisor == 1)

            try await harness.evaluate("readerSetPageLayout('double')")
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await harness.geometry().renderedDivisor == 1)
            let state = try await harness.pageLayoutState()
            #expect(state.applied?.pages == 1)
        }
    }

    // MARK: Layout messages (requested vs effective)

    @Test("the page reports requested and effective layout through layoutChanged")
    func layoutChangedMessages() async throws {
        let harness = try makeHarness(width: 600, height: 650)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)

        let initial = try await harness.waitForMessage(
            "layoutChanged",
            matching: { $0["requested"] as? String == "automatic" },
            "the initial layout message"
        )
        #expect(initial["pages"] as? Int == 1)

        // Two Pages requested in a narrow window: the effective count still
        // reports one page, which is what the popover explains.
        try await harness.evaluate("readerSetPageLayout('double')")
        let fallback = try await harness.waitForMessage(
            "layoutChanged",
            matching: { $0["requested"] as? String == "double" },
            "the double fallback message"
        )
        #expect(fallback["pages"] as? Int == 1)

        // Widening recovers the requested mode without touching it again.
        try await harness.resize(to: CGSize(width: 1000, height: 700))
        let recovered = try await harness.waitForMessage(
            "layoutChanged",
            matching: { $0["requested"] as? String == "double" && $0["pages"] as? Int == 2 },
            "the recovered two-page message"
        )
        #expect(recovered["pages"] as? Int == 2)

        try await harness.evaluate("readerSetPageLayout('single')")
        let pinned = try await harness.waitForMessage(
            "layoutChanged",
            matching: { $0["requested"] as? String == "single" },
            "the single-page message"
        )
        #expect(pinned["pages"] as? Int == 1)
    }

    @Test("iOS never posts desktop layout messages")
    func iosHasNoLayoutMessages() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load(platform: nil, typography: (16, 1.65, 0, "px"))
        _ = try await harness.waitForRelocation(after: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.relocationCount > 0)
        // The iOS platform flag gates the desktop policy, so the page never
        // reports a page-layout state the iOS shell has no UI for.
        #expect(harness.messageCount(of: "layoutChanged") == 0)
    }

    // MARK: Passage preservation through reflow

    /// The paragraph nearest the middle of the visible page. A page-start
    /// CFI sits on a paragraph boundary, so the topmost paragraph can
    /// legitimately slide to the neighbouring page after repagination;
    /// mid-page text must not.
    private func anchorParagraph(_ harness: ReaderLayoutHarness) async throws -> String {
        let rects = try await harness.visibleParagraphRects()
        let geometry = try await harness.geometry()
        let center = geometry.innerHeight / 2
        let nearest = rects.min(by: {
            abs(($0.top + $0.bottom) / 2 - center) < abs(($1.top + $1.bottom) / 2 - center)
        })
        return try #require(nearest?.id)
    }

    @Test("a text-size change keeps the visible passage")
    func textSizeChangeKeepsPassage() async throws {
        let harness = try makeHarness(width: 900, height: 700)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(1)
        var visible = try await harness.visibleParagraphIDs()

        try await harness.evaluate("readerScrollBy(1)")
        visible = try await harness.waitForVisibleParagraphChange(from: visible)
        try await harness.waitForReaderIdle()
        let anchor = try await anchorParagraph(harness)

        try await harness.evaluate("readerApplyTypography(160,1.6,72,'%')")
        try await harness.waitForLayoutSettled()

        let after = try await harness.visibleParagraphIDs()
        #expect(after.contains(anchor), "anchor \(anchor) left the screen after a text-size change")
    }

    @Test("a mode change keeps the visible passage")
    func modeChangeKeepsPassage() async throws {
        let harness = try makeHarness(width: 1400, height: 800)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(2)
        var visible = try await harness.visibleParagraphIDs()

        try await harness.evaluate("readerScrollBy(1)")
        visible = try await harness.waitForVisibleParagraphChange(from: visible)
        try await harness.waitForReaderIdle()
        let anchor = try await anchorParagraph(harness)

        try await harness.evaluate("readerSetPageLayout('single')")
        _ = try await harness.waitForDivisor(1)
        try await harness.waitForLayoutSettled()
        var after = try await harness.visibleParagraphIDs()
        #expect(after.contains(anchor), "anchor \(anchor) left the screen after switching to one page")

        try await harness.evaluate("readerSetPageLayout('double')")
        _ = try await harness.waitForDivisor(2)
        try await harness.waitForLayoutSettled()
        after = try await harness.visibleParagraphIDs()
        #expect(after.contains(anchor), "anchor \(anchor) left the screen after switching back to two pages")
    }

    @Test("rapid alternating widths settle on the passage")
    func rapidResizesKeepPassage() async throws {
        let harness = try makeHarness(width: 900, height: 700)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(1)
        var visible = try await harness.visibleParagraphIDs()

        try await harness.evaluate("readerScrollBy(1)")
        visible = try await harness.waitForVisibleParagraphChange(from: visible)
        try await harness.waitForReaderIdle()
        let anchor = try await anchorParagraph(harness)

        // Drag-like burst: several widths before the scheduler fires.
        for width in [1400.0, 700.0, 1300.0, 800.0, 1200.0, 900.0] {
            try await harness.setViewport(width: width, height: 700)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await harness.waitForLayoutSettled()

        let after = try await harness.visibleParagraphIDs()
        #expect(after.contains(anchor), "anchor \(anchor) left the screen after rapid resizes")
    }

    @Test("navigation during reflow wins over the old anchor")
    func navigationDuringReflowWins() async throws {
        let harness = try makeHarness(width: 1200, height: 760)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        try await harness.waitForReaderIdle()
        let before = try await harness.visibleParagraphIDs()
        #expect(before.isEmpty == false)

        // Start a reflow, then jump elsewhere before it settles.
        try await harness.setViewport(width: 800, height: 760)
        try await harness.evaluate("readerDisplay('ch4.xhtml#p-4-04')")
        _ = try await harness.waitForVisibleParagraph("p-4-04")
        try await harness.waitForLayoutSettled()

        let after = try await harness.visibleParagraphIDs()
        #expect(after.contains("p-4-04"))
        // The stale anchor must not drag the reader back to chapter one.
        #expect(after.contains(where: { $0.hasPrefix("p-1-") }) == false)
    }

    @Test("a settled reflow never leaves a blank page or duplicate views")
    func reflowLeavesOneVisibleView() async throws {
        let harness = try makeHarness(width: 1000, height: 700)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        try await harness.waitForDivisor(1)

        try await harness.evaluate("readerApplyTypography(140,1.6,72,'%')")
        try await harness.waitForLayoutSettled()

        let geometry = try await harness.geometry()
        #expect(geometry.iframeCount == 1)
        let visibleIframes = try await harness.visibleIframeCount()
        #expect(visibleIframes == 1)
        #expect(try await harness.visibleParagraphIDs().isEmpty == false)
        // No error page replaced the reader.
        let body = try await harness.evaluate(
            "document.querySelector('.reader-error') ? 'error' : 'ok'"
        ) as? String
        #expect(body == "ok")
    }

    // MARK: iOS preservation

    @Test("the iOS page keeps its full-width single-column behavior")
    func iosPageIsUnchanged() async throws {
        let harness = try makeHarness(width: 1200, height: 760)
        defer { harness.dismantle() }
        try await harness.load(platform: nil, typography: (16, 1.65, 0, "px"))
        _ = try await harness.waitForRelocation(after: 0)

        let geometry = try await harness.geometry()
        #expect(geometry.renderedDivisor == 1)
        #expect(abs(geometry.columnWidth - geometry.stageWidth) < 1)
        // lineWidthCh = 0 disables the measure: the viewer fills the page.
        #expect(abs(geometry.viewerWidth - geometry.innerWidth) < 1)
        // iOS spacing is unchanged: the CSS 1.4rem padding, not 24 px.
        #expect(abs(geometry.viewerPaddingLeft - 22.4) < 0.5)
        // The engine is never asked for two columns on iOS.
        let spread = try await harness.evaluate("readerRendition.settings.spread") as? String
        #expect(spread == "none")
        #expect(try await harness.visibleParagraphIDs().isEmpty == false)
    }

    // MARK: Page traversal over the fixture

    @Test("page turns traverse every paragraph in order across chapter boundaries")
    func pageTurnsCoverEveryParagraph() async throws {
        let harness = try makeHarness(width: 900, height: 700)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        // Let the initial typography measurement and its debounced relayout
        // settle before walking the book.
        _ = try await harness.waitForDivisor(1)
        try await Task.sleep(for: .milliseconds(300))

        var observed: [String] = []
        func appendVisible(_ ids: [String]) {
            for id in ids where observed.last != id {
                observed.append(id)
            }
        }
        var visible = try await harness.visibleParagraphIDs()
        appendVisible(visible)

        // Forward until the last section's final paragraph is on screen or
        // two consecutive turns stop changing the visible text (end of book).
        var stalled = 0
        for _ in 0..<40 {
            try await harness.evaluate("readerScrollBy(1)")
            do {
                visible = try await harness.waitForVisibleParagraphChange(from: visible, timeout: 3)
                // Let the rendition queue drain before the next turn:
                // visibility can flip while the engine still has a
                // cross-section append queued.
                try await harness.waitForReaderIdle()
                visible = try await harness.visibleParagraphIDs()
                appendVisible(visible)
            } catch {
                stalled += 1
                if stalled >= 2 { break }
                continue
            }
            if observed.contains("p-5-03") { break }
        }

        var expected: [String] = []
        for section in 1...5 {
            let count = section == 5 ? 3 : 8
            for index in 1...count {
                expected.append(String(format: "p-%d-%02d", section, index))
            }
            // The cross-section link paragraph sits after the last
            // paragraph of section one.
            if section == 1 {
                expected.append("link-to-ch3")
            }
        }
        #expect(observed == expected, "saw \(observed)")
    }

    private func glyphWidth(_ harness: ReaderLayoutHarness) async throws -> Double {
        try await harness.pageLayoutState().glyphWidthPx
    }

    private func advertisedLineWidth(_ harness: ReaderLayoutHarness) async throws -> Double {
        try await harness.evaluate("readerTypography.lineWidthCh") as? Double ?? 72
    }
}
#endif
