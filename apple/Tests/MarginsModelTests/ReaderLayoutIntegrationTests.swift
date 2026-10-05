#if os(macOS)
import CoreGraphics
import Foundation
import MarginsCore
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
        // Passage on screen, not an exact relocated CFI: display() can
        // resolve while currentLocation is still the previous page.
        let expected = try #require(visible.first)
        try await reopened.waitForVisibleParagraph(expected, timeout: 30)
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
            let pages =
                try await harness.evaluate(
                    "window.readerResolveLayout(\(options)).pages"
                ) as? Int
            #expect(pages == expected, "policy case \(options)")
        }
        // The viewer cap keeps the selected measure: single page = 48 +
        // lineWidthCh * glyph; two pages add the gutter and a second page.
        let singleWidth =
            try await harness.evaluate(
                "window.readerResolveLayout({mode:'single',widthPx:1400,glyphWidthPx:8,lineWidthCh:72}).viewerWidthPx"
            ) as? Double
        #expect(singleWidth == 624)
        let doubleWidth =
            try await harness.evaluate(
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
        // Text fragments run slightly inside the paragraph box; the page's
        // measure must not overflow it, and text must fill most of it.
        #expect(narrowMeasure <= narrow.stageWidth - 40 + 4)
        #expect(narrowMeasure >= narrow.stageWidth - 40 - 60)

        try await harness.resize(to: CGSize(width: 1500, height: 800))
        let wide = try await harness.waitForDivisor(2)
        // Two pages: each measure is half the stage after the outer body
        // padding and the fixed 40 px gutter.
        #expect(abs(wide.gap - 40) < 1)
        let wideRects = try await harness.visibleParagraphRects()
        #expect(wideRects.count >= 2)
        let widest = try #require(wideRects.map(\.width).max())
        let expectedMeasure = (wide.stageWidth - 80) / 2
        #expect(widest <= expectedMeasure + 4)
        #expect(widest >= expectedMeasure - 60)
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
        let margins =
            try await harness.evaluate(
                "window.innerWidth - document.getElementById('viewer').getBoundingClientRect().right"
            ) as? Double
        let left =
            try await harness.evaluate(
                "document.getElementById('viewer').getBoundingClientRect().left"
            ) as? Double
        #expect(abs((margins ?? 0) - (left ?? 0)) < 1)
        #expect(geometry.viewerWidth < geometry.innerWidth)
        let rects = try await harness.visibleParagraphRects()
        let measure = try #require(rects.first?.width)
        #expect(measure <= geometry.stageWidth - 40 + 4)
        #expect(measure >= geometry.stageWidth - 40 - 60)
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

        try await harness.resize(to: CGSize(width: 1100, height: 700))
        let wide = try await harness.waitForDivisor(2)
        #expect(wide.gap == 40)
    }

    @Test("a larger body font can force Automatic back to one page")
    func largeTextTriggersFallback() async throws {
        let harness = try makeHarness(width: 1500, height: 820)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(2)

        try await harness.evaluate("readerApplyTypography(210,1.6,72,'%')")
        _ = try await harness.waitForDivisor(1)

        // Back to the default size: the wider viewport fits two pages again.
        try await harness.evaluate("readerApplyTypography(120,1.6,72,'%')")
        _ = try await harness.waitForDivisor(2)
    }

    @Test("Automatic uses hysteresis around the fit threshold")
    func automaticHysteresis() async throws {
        let harness = try makeHarness(width: 1500, height: 820)
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
        try await harness.resize(to: CGSize(width: 1100, height: 700))
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

    // MARK: Visible range endpoints

    @Test("a two-page spread reports its second page as the endpoint")
    func spreadReportsEndpoint() async throws {
        let harness = try makeHarness(width: 1500, height: 800)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(2)

        let relocation = try await harness.waitForMessage(
            "relocated",
            matching: {
                guard let page = $0["page"] as? Int, let endPage = $0["endPage"] as? Int else {
                    return false
                }
                return endPage > page
            },
            "a spread-sized relocation"
        )
        let page = try #require(relocation["page"] as? Int)
        let endPage = try #require(relocation["endPage"] as? Int)
        #expect(endPage == page + 1)
        #expect(relocation["endHref"] as? String == relocation["href"] as? String)
        #expect(relocation["endCfi"] as? String != relocation["cfi"] as? String)
    }

    @Test("a single page reports its own page as the endpoint")
    func singlePageReportsItself() async throws {
        let harness = try makeHarness(width: 900, height: 700)
        defer { harness.dismantle() }
        try await harness.load()
        let relocation = try await harness.waitForRelocation(after: 0)
        let page = try #require(relocation["page"] as? Int)
        #expect(relocation["endPage"] as? Int == page)
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
        let harness = try makeHarness(width: 1500, height: 800)
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

        // Drag-like burst: several widths before the scheduler fires, wide
        // enough to cross the 120 % default's two-page threshold (~1440 px).
        for width in [1600.0, 700.0, 1500.0, 800.0, 1300.0, 900.0] {
            try await harness.setViewport(width: width, height: 700)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await harness.waitForLayoutSettled()

        let after = try await harness.visibleParagraphIDs()
        #expect(after.contains(anchor), "anchor \(anchor) left the screen after rapid resizes")
    }

    @Test("settled resizes never ratchet the passage backward")
    func settledResizesKeepPassage() async throws {
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

        // Each width settles fully, so every reflow must restore the
        // passage — an anchor that drifts early compounds across steps.
        for width in [600.0, 900.0, 650.0, 900.0, 700.0, 900.0] {
            try await harness.resize(to: CGSize(width: width, height: 700))
            try await harness.waitForLayoutSettled()
            if width == 900 {
                #expect(
                    try await harness.visibleParagraphIDs().contains(anchor),
                    "anchor \(anchor) left the screen after settled resize to \(width)")
            }
        }
    }

    @Test("window resize repairs the passage when policy geometry is unchanged")
    func windowResizeRestoresUnchangedGeometry() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        _ = try await harness.waitForDivisor(1)
        var visible = try await harness.visibleParagraphIDs()
        _ = try await harness.evaluate("readerScrollBy(1)")
        visible = try await harness.waitForVisibleParagraphChange(from: visible)
        try await harness.waitForReaderIdle()
        let anchor = try await anchorParagraph(harness)
        let before = try await harness.geometry()
        let generation = try #require(try await harness.evaluate("readerLayoutGeneration") as? Int)
        _ = try await harness.evaluate(
            "readerViewportObserver.disconnect(); window.dispatchEvent(new Event('resize'))"
        )
        try await harness.waitForLayoutSettled()
        let repaired = try #require(try await harness.evaluate("readerLayoutGeneration") as? Int)
        let after = try await harness.geometry()
        let paragraphs = try await harness.visibleParagraphIDs()
        #expect(repaired > generation)
        #expect(abs(after.viewerWidth - before.viewerWidth) < 1)
        #expect(after.renderedDivisor == before.renderedDivisor)
        #expect(paragraphs.contains(anchor))
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
        let body =
            try await harness.evaluate(
                "document.querySelector('.reader-error') ? 'error' : 'ok'"
            ) as? String
        #expect(body == "ok")
    }

    @Test("layout waits reject unfinished navigation")
    func layoutWaitRejectsPendingNavigation() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        try await harness.waitForLayoutSettled()

        _ = try await harness.evaluate("readerBeginNavigation()")
        await #expect(throws: ReaderLayoutHarnessError.self) {
            try await harness.waitForLayoutSettled(timeout: 0.2)
        }
        _ = try await harness.evaluate("readerEndNavigation()")
        try await harness.waitForLayoutSettled()
    }

    @Test("idle waits reject unfinished navigation")
    func idleWaitRejectsPendingNavigation() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        try await harness.waitForLayoutSettled()

        _ = try await harness.evaluate("readerBeginNavigation()")
        await #expect(throws: ReaderLayoutHarnessError.self) {
            try await harness.waitForReaderIdle(timeout: 0.2)
        }
        _ = try await harness.evaluate("readerEndNavigation()")
        try await harness.waitForReaderIdle()
    }

    @Test("an empty queue is not idle while its job is running")
    func idleWaitRejectsRunningQueueJob() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)
        try await harness.waitForReaderIdle()

        _ = try await harness.evaluate(
            "void readerRendition.q.enqueue(function() { return new Promise(function(resolve) { window.__marginsResolveQueueJob = resolve; readerPost({type:'testQueueRunning'}); }); });"
        )
        _ = try await harness.waitForMessage(
            "testQueueRunning", matching: nil, "the deliberately pending queue job")
        #expect(try await harness.evaluate("readerRendition.q._q.length") as? Int == 0)
        #expect(try await harness.evaluate("!!readerRendition.q.running") as? Bool == true)
        await #expect(throws: ReaderLayoutHarnessError.self) {
            try await harness.waitForReaderIdle(timeout: 0.2)
        }
        _ = try await harness.evaluate(
            "window.__marginsResolveQueueJob(); delete window.__marginsResolveQueueJob"
        )
        try await harness.waitForReaderIdle()
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

    private func fixtureBook() -> BookMeta {
        BookMeta(
            id: "fixture-book",
            title: "Reader Fixture",
            author: "",
            addedAt: Date(timeIntervalSince1970: 0),
            sourceFilename: "reflowable.epub",
            chapters: (1...5).map {
                ChapterMeta(
                    key: "c\($0)", index: $0 - 1, title: "Ch \($0)",
                    href: "ch\($0).xhtml", fragment: nil
                )
            },
            coverPath: nil,
            progressPercent: nil
        )
    }

    private func feedRelocation(_ relocation: [String: Any], to reader: ReaderModel) {
        reader.relocated(
            page: (relocation["page"] as? Int) ?? 1,
            totalPages: (relocation["totalPages"] as? Int) ?? 0,
            href: relocation["href"] as? String,
            cfi: relocation["cfi"] as? String,
            endPage: relocation["endPage"] as? Int,
            endHref: relocation["endHref"] as? String,
            endCfi: relocation["endCfi"] as? String
        )
    }

    private func currentLocation(_ harness: ReaderLayoutHarness) async throws -> [String: Any] {
        guard
            let location = try await harness.evaluateJSON(
                """
                (function() {
                  var l = readerRendition.currentLocation();
                  var s = l && l.start ? l.start : {};
                  var e = l && l.end ? l.end : {};
                  return {
                    cfi: s.cfi || null,
                    href: s.href || null,
                    page: s.displayed ? s.displayed.page : null,
                    totalPages: s.displayed ? s.displayed.total : null,
                    endCfi: e.cfi || null,
                    endHref: e.href || null,
                    endPage: e.displayed ? e.displayed.page : null
                  };
                })()
                """
            ) as? [String: Any]
        else {
            throw ReaderLayoutHarnessError.javaScript("currentLocation")
        }
        return location
    }

    private func paragraphID(
        _ harness: ReaderLayoutHarness, containing cfi: String
    ) async throws -> (id: String, index: Int) {
        let script = """
            (function() {
              var range = readerRendition.getRange(\(jsLiteral(cfi)));
              var node = range && range.startContainer;
              if (!node) { return null; }
              var el = node.nodeType === 1 ? node : node.parentElement;
              var p = el && el.closest ? el.closest("p[id]") : null;
              var doc = node.ownerDocument;
              var paras = doc ? Array.prototype.slice.call(doc.querySelectorAll("p[id]")) : [];
              if (!p) {
                p = paras.filter(function(candidate) {
                  return (node.compareDocumentPosition(candidate)
                    & Node.DOCUMENT_POSITION_PRECEDING) === 0;
                })[0] || null;
              }
              if (!p) { return null; }
              return { id: p.id, index: paras.indexOf(p) };
            })()
            """
        guard let hit = try await harness.evaluateJSON(script) as? [String: Any],
            let id = hit["id"] as? String, let index = hit["index"] as? Int
        else { throw ReaderLayoutHarnessError.javaScript("paragraphID") }
        return (id, index)
    }

    private func savedSpotAcceptance(
        _ harness: ReaderLayoutHarness,
        pinId: String,
        initialTypography: String?,
        reflowTypography: String
    ) async throws {
        if let initialTypography {
            try await harness.evaluate(initialTypography)
            try await harness.waitForLayoutSettled()
        }
        var settled = try await harness.waitForRelocation(after: 0)
        var anchorCfi = try #require(settled["cfi"] as? String)
        var anchor = try await paragraphID(harness, containing: anchorCfi)
        for _ in 0..<8 where anchor.index < 2 {
            try await harness.evaluate("readerScrollBy(1)")
            settled = try await harness.waitForRelocationChange(from: settled)
            try await harness.waitForReaderIdle()
            anchorCfi = try #require(settled["cfi"] as? String)
            anchor = try await paragraphID(harness, containing: anchorCfi)
        }
        #expect(anchor.index >= 2)

        let book = fixtureBook()
        let reader = ReaderModel()
        reader.open(book: book, chapter: book.chapters[0])
        feedRelocation(settled, to: reader)

        let anchorId = anchor.id
        let pin = Bookmark(
            id: pinId, label: "", chapterKey: reader.chapter!.key,
            epubCfi: anchorCfi, percent: 20,
            createdAt: Date(), updatedAt: Date()
        )
        reader.bookmarksUpdated([pin])
        #expect(reader.pageIsBookmarked)
        #expect(reader.bookmarksOnPage == [pin])

        try await harness.evaluate(reflowTypography)
        try await harness.waitForLayoutSettled()
        var current = try await currentLocation(harness)
        feedRelocation(current, to: reader)
        let newStart = try #require(current["cfi"] as? String)
        let newEnd = try #require(current["endCfi"] as? String)
        #expect(newStart != anchorCfi)
        #expect(CFI.comparePoints(newStart, anchorCfi) == .orderedAscending)
        #expect(CFI.comparePoints(anchorCfi, newEnd) != .orderedDescending)
        #expect(reader.pageIsBookmarked)
        #expect(reader.bookmarks == [pin])

        var away = current
        for _ in 0..<6 {
            try await harness.evaluate("readerScrollBy(1)")
            away = try await harness.waitForRelocationChange(from: away)
            try await harness.waitForReaderIdle()
            feedRelocation(away, to: reader)
            if !reader.pageIsBookmarked { break }
        }
        #expect(!reader.pageIsBookmarked)
        #expect(reader.bookmarks == [pin])

        try await harness.evaluate("readerDisplay(\(jsLiteral(anchorCfi)))")
        try await harness.waitForVisibleParagraph(anchorId)
        try await harness.waitForReaderIdle()
        current = try await currentLocation(harness)
        feedRelocation(current, to: reader)
        #expect(reader.pageIsBookmarked)
        #expect(reader.bookmarks == [pin])
    }

    @Test("a saved spot stays bookmarked across reflow on the desktop spread")
    func savedSpotStaysBookmarkedThroughReflow() async throws {
        let harness = try makeHarness(width: 1500, height: 800)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForDivisor(2)
        try await savedSpotAcceptance(
            harness,
            pinId: "pin0000001",
            initialTypography: "readerApplyTypography(210,1.6,72,'%')",
            reflowTypography: "readerApplyTypography(120,1.6,72,'%')"
        )
    }

    @Test("a saved spot stays bookmarked on the single-column iOS page")
    func savedSpotStaysBookmarkedOnIOSPage() async throws {
        let harness = try makeHarness(width: 900, height: 700)
        defer { harness.dismantle() }
        try await harness.load(platform: nil, typography: (16, 1.65, 0, "px"))
        try await savedSpotAcceptance(
            harness,
            pinId: "pin0000002",
            initialTypography: nil,
            reflowTypography: "readerApplyTypography(20,1.65,0,'px')"
        )
    }

    // MARK: Typeface

    @Test("each face resolves its family in section documents; Easy loads the bundled font and its fixed spacing")
    func typefacesApplyInSectionDocuments() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load(typography: (120, 1.6, 72, "%"))

        // Easy: the bundled face is served over the scheme handler into the
        // section document (a FontFace for the family reaches "loaded"),
        // pins letter/word spacing, and boosts the chosen 1.6 line height
        // by 0.15.
        try await harness.evaluate("readerSetFontFace('easy')")
        try await harness.waitForLayoutSettled()
        let easy = try await sectionTypography(harness, loadFont: true)
        #expect((easy["atkinsonLoaded"] as? Int ?? 0) >= 1)
        #expect((easy["atkinsonStatuses"] as? [String] ?? []).contains("loaded"))
        let easyFamily = try #require(easy["fontFamily"] as? String)
        #expect(unquoted(easyFamily).hasPrefix("Atkinson Hyperlegible Next"))
        let easyFontSize = try #require(px(easy["fontSize"]))
        let easyLetterSpacing = try #require(px(easy["letterSpacing"]))
        let easyWordSpacing = try #require(px(easy["wordSpacing"]))
        #expect(abs(easyLetterSpacing - easyFontSize * 0.03) < 0.02)
        #expect(abs(easyWordSpacing - easyFontSize * 0.08) < 0.05)
        let easyRatio = try #require(px(easy["lineHeight"])) / easyFontSize
        #expect(abs(easyRatio - 1.75) < 0.01)

        // The boost is capped: 2.1 + 0.15 lands on 2.2, not 2.25.
        try await harness.evaluate("readerApplyTypography(120,2.1,72,'%')")
        try await harness.waitForLayoutSettled()
        let capped = try await sectionTypography(harness, loadFont: false)
        let cappedFontSize = try #require(px(capped["fontSize"]))
        let cappedRatio = try #require(px(capped["lineHeight"])) / cappedFontSize
        #expect(abs(cappedRatio - 2.2) < 0.01)

        // Sans and Serif keep publisher spacing and the chosen line height.
        try await harness.evaluate("readerApplyTypography(120,1.6,72,'%')")
        try await harness.evaluate("readerSetFontFace('sans')")
        try await harness.waitForLayoutSettled()
        let sans = try await sectionTypography(harness, loadFont: false)
        let sansFamily = try #require(sans["fontFamily"] as? String)
        #expect(unquoted(sansFamily).hasPrefix("Seravek"))
        #expect(px(sans["letterSpacing"]) ?? 0 == 0)
        #expect(px(sans["wordSpacing"]) ?? 0 == 0)
        let sansFontSize = try #require(px(sans["fontSize"]))
        let sansRatio = try #require(px(sans["lineHeight"])) / sansFontSize
        #expect(abs(sansRatio - 1.6) < 0.01)

        try await harness.evaluate("readerSetFontFace('serif')")
        try await harness.waitForLayoutSettled()
        let serif = try await sectionTypography(harness, loadFont: false)
        let serifFamily = try #require(serif["fontFamily"] as? String)
        #expect(unquoted(serifFamily).hasPrefix("Charter"))
    }

    /// The visible section document's first paragraph computed style, plus
    /// the FontFace status of the bundled family inside that document.
    /// `loadFont` first asks the section's FontFaceSet to load the family —
    /// its resolution proves the scheme handler served the font bytes.
    private func sectionTypography(
        _ harness: ReaderLayoutHarness,
        loadFont: Bool
    ) async throws -> [String: Any] {
        if loadFont {
            // evaluateJavaScript does not await promises, so the
            // FontFaceSet.load result is stashed on window for the poll.
            _ = try await harness.evaluate(
                """
                (function() {
                  var doc = null;
                  var frames = document.querySelectorAll('iframe');
                  for (var i = 0; i < frames.length; i++) {
                    var r = frames[i].getBoundingClientRect();
                    if (r.width <= 0 || r.height <= 0) { continue; }
                    if (window.getComputedStyle(frames[i]).visibility === 'hidden') { continue; }
                    try { doc = frames[i].contentDocument; } catch (e) { continue; }
                    if (doc && doc.querySelector('p')) { break; }
                    doc = null;
                  }
                  window.__marginsFontCheck = { error: 'no visible section document' };
                  if (doc && doc.fonts && doc.fonts.load) {
                    window.__marginsFontCheck = null;
                    doc.fonts.load("16px 'Atkinson Hyperlegible Next'").then(function(faces) {
                      window.__marginsFontCheck = { loaded: faces.length };
                    }).catch(function(e) {
                      window.__marginsFontCheck = { error: String(e) };
                    });
                  }
                  return true;
                })()
                """
            )
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let check = try await harness.evaluate("window.__marginsFontCheck") as? [String: Any],
                    !(check is NSNull)
                {
                    if let error = check["error"] as? String {
                        Issue.record("font load: \(error)")
                    }
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let script = """
            (function() {
              var frames = document.querySelectorAll('iframe');
              for (var i = 0; i < frames.length; i++) {
                var r = frames[i].getBoundingClientRect();
                if (r.width <= 0 || r.height <= 0) { continue; }
                if (window.getComputedStyle(frames[i]).visibility === 'hidden') { continue; }
                var doc = null;
                try { doc = frames[i].contentDocument; } catch (e) { continue; }
                if (!doc || !doc.querySelector('p')) { continue; }
                var cs = frames[i].contentWindow.getComputedStyle(doc.querySelector('p'));
                var atkinson = [];
                if (doc.fonts && doc.fonts.forEach) {
                  doc.fonts.forEach(function(face) {
                    if (face.family.indexOf('Atkinson') !== -1) { atkinson.push(face.status); }
                  });
                }
                var check = window.__marginsFontCheck || {};
                return {
                  fontFamily: cs.fontFamily,
                  letterSpacing: cs.letterSpacing,
                  wordSpacing: cs.wordSpacing,
                  lineHeight: cs.lineHeight,
                  fontSize: cs.fontSize,
                  atkinsonStatuses: atkinson,
                  atkinsonLoaded: check.loaded || 0
                };
              }
              return { error: 'no visible section document' };
            })()
            """
        guard let result = try await harness.evaluate(script) as? [String: Any] else {
            throw ReaderLayoutHarnessError.javaScript("sectionTypography")
        }
        if let error = result["error"] as? String {
            Issue.record("\(error)")
        }
        return result
    }

    /// Drops the quote characters WebKit wraps around computed
    /// font-family names, so a family prefix can be compared plainly.
    private func unquoted(_ family: String) -> String {
        family.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    /// Parses a computed CSS length like "19.2px"; nil for keywords such as
    /// "normal".
    private func px(_ value: Any?) -> Double? {
        guard let string = value as? String else { return nil }
        return Double(string.replacingOccurrences(of: "px", with: ""))
    }

    private func glyphWidth(_ harness: ReaderLayoutHarness) async throws -> Double {
        try await harness.pageLayoutState().glyphWidthPx
    }

    private func advertisedLineWidth(_ harness: ReaderLayoutHarness) async throws -> Double {
        try await harness.evaluate("readerTypography.lineWidthCh") as? Double ?? 72
    }

    // MARK: Prose options (justify, ornaments, book language)

    /// `text-align|hyphens` computed on a body paragraph — the pair
    /// `readerSetProse` switches. WebKit reports `-webkit-hyphens`.
    private func proseAlignAndHyphens(
        _ harness: ReaderLayoutHarness, paragraphID: String = "p-1-01"
    ) async throws -> (align: String?, hyphens: String?) {
        let css = try await harness.evaluate(
            """
            (function () {
              var doc = readerRendition.getContents()[0].document;
              var p = doc.querySelector("#\(paragraphID)");
              var cs = doc.defaultView.getComputedStyle(p);
              var h = cs.getPropertyValue("hyphens")
                || cs.getPropertyValue("-webkit-hyphens");
              return cs.textAlign + "|" + h;
            })()
            """
        ) as? String
        let parts = css?.split(separator: "|") ?? []
        return (parts.first.map(String.init), parts.count > 1 ? String(parts[1]) : nil)
    }

    /// `-webkit-initial-letter|font-variant-caps` computed on the
    /// chapter-opening paragraph — the ornament pair.
    private func openingOrnaments(
        _ harness: ReaderLayoutHarness, paragraphID: String = "p-1-01"
    ) async throws -> (letter: String?, caps: String?) {
        let css = try await harness.evaluate(
            """
            (function () {
              var doc = readerRendition.getContents()[0].document;
              var p = doc.querySelector("#\(paragraphID)");
              var view = doc.defaultView;
              var fl = view.getComputedStyle(p, "::first-letter");
              var fn = view.getComputedStyle(p, "::first-line");
              var il = fl.getPropertyValue("-webkit-initial-letter")
                || fl.getPropertyValue("initial-letter");
              return il + "|" + fn.getPropertyValue("font-variant-caps");
            })()
            """
        ) as? String
        let parts = css?.split(separator: "|") ?? []
        return (parts.first.map(String.init), parts.count > 1 ? String(parts[1]) : nil)
    }

    /// The fixture's publisher sheet justifies `p`; the reader forces
    /// left until justify is on — then alignment flips and hyphenation
    /// turns on (the load carried a book language).
    @Test("justify switches body text to justified with hyphenation")
    func justifyTogglesAlignment() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load(language: "en")

        var prose = try await proseAlignAndHyphens(harness)
        #expect(prose.align == "left")
        #expect(prose.hyphens != "auto")

        _ = try await harness.evaluate("readerSetProse(true, true); \"sent\"")
        prose = try await proseAlignAndHyphens(harness)
        #expect(prose.align == "justify")
        #expect(prose.hyphens == "auto")

        _ = try await harness.evaluate("readerSetProse(false, true); \"sent\"")
        prose = try await proseAlignAndHyphens(harness)
        #expect(prose.align == "left")
        #expect(prose.hyphens != "auto")
    }

    /// The Easy face ignores justify — its spacing is the point.
    @Test("the Easy face keeps flush-left text even when justify is on")
    func easyStaysFlushLeft() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load(language: "en")

        _ = try await harness.evaluate(
            "readerSetFontFace(\"easy\"); readerSetProse(true, true); \"sent\""
        )
        let prose = try await proseAlignAndHyphens(harness)
        #expect(prose.align == "left")

        _ = try await harness.evaluate("readerSetFontFace(\"serif\"); \"sent\"")
        let after = try await proseAlignAndHyphens(harness)
        #expect(after.align == "justify")
        #expect(after.hyphens == "auto")
    }

    /// With ornaments on, the paragraph right after the chapter heading
    /// gets a three-line initial letter and a small-caps first line;
    /// off — or the Easy face — leaves it plain. A mid-chapter paragraph
    /// is never ornamented.
    @Test("chapter ornaments mark only the opening paragraph")
    func ornamentsMarkOpeningParagraph() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load()

        var ornament = try await openingOrnaments(harness)
        #expect(ornament.letter == "3")
        #expect(ornament.caps == "small-caps")
        let mid = try await openingOrnaments(harness, paragraphID: "p-1-02")
        #expect(mid.letter == "normal" || mid.letter == nil || mid.letter == "")
        #expect(mid.caps != "small-caps")

        _ = try await harness.evaluate("readerSetProse(false, false); \"sent\"")
        ornament = try await openingOrnaments(harness)
        #expect(ornament.letter == "normal" || ornament.letter == "")

        _ = try await harness.evaluate(
            "readerSetFontFace(\"easy\"); readerSetProse(false, true); \"sent\""
        )
        ornament = try await openingOrnaments(harness)
        #expect(ornament.letter == "normal" || ornament.letter == "")
    }

    /// The book language lands on a section only when the document
    /// declares none of its own — the fixture's html carries lang="en",
    /// so it wins; stripped, the book's fills the gap.
    @Test("the book language fills unlang'd sections but never overrides")
    func bookLanguageFillsOnlyWhenAbsent() async throws {
        let harness = try makeHarness()
        defer { harness.dismantle() }
        try await harness.load(language: "de")

        // The fixture's own declaration wins over the URL's book language.
        var lang = try await harness.evaluate(
            "readerRendition.getContents()[0].document.documentElement.getAttribute(\"lang\")"
        ) as? String
        #expect(lang == "en")

        // A section with no language of its own takes the book's.
        lang = try await harness.evaluate(
            """
            (function () {
              var contents = readerRendition.getContents()[0];
              var html = contents.document.documentElement;
              html.removeAttribute("lang");
              html.removeAttribute("xml:lang");
              readerStyleContents(contents);
              return html.getAttribute("lang");
            })()
            """
        ) as? String
        #expect(lang == "de")
    }
}
#endif
