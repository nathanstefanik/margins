#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import MarginsModel

/// Phase 1 acceptance cases: the fixture harness drives the real reader
/// page through opening, CFI navigation, and paging. The geometry these
/// cases record is the one-page baseline the layout policy must preserve
/// at `spread: "none"`.
///
/// Serialized: each case starts a WebKit content process, and the suite
/// runs inside one shared test process.
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

    @Test("the RTL fixture opens and pages forward")
    func rtlFixtureOpens() async throws {
        let harness = try makeHarness(.rtl)
        defer { harness.dismantle() }
        try await harness.load()
        let first = try await harness.waitForRelocation(after: 0)
        #expect((first["href"] as? String)?.hasSuffix("ch1.xhtml") == true)
        #expect((first["totalPages"] as? Int ?? 0) > 0)
        #expect(try await harness.visibleParagraphIDs().isEmpty == false)

        try await harness.evaluate("readerScrollBy(1)")
        let second = try await harness.waitForRelocationChange(from: first)
        #expect(second["cfi"] as? String != first["cfi"] as? String)
    }

    @Test("the fixed-layout fixture opens")
    func fixedLayoutFixtureOpens() async throws {
        let harness = try makeHarness(.fixedLayout)
        defer { harness.dismantle() }
        try await harness.load(chapter: "page1.xhtml")
        let relocation = try await harness.waitForRelocation(after: 0)
        #expect((relocation["cfi"] as? String)?.isEmpty == false)
        #expect(try await harness.visibleParagraphIDs().isEmpty == false)
    }

    /// The one-page baseline. These viewports are test dimensions, not
    /// claimed hardware resolutions; the measured values feed
    /// docs/testing/macos-reader-layout.md.
    @Test(
        "one-page baselines hold across content viewports",
        arguments: [
            (600.0, 650.0),
            (900.0, 700.0),
            (1200.0, 760.0),
            (1440.0, 820.0),
        ]
    )
    func onePageBaselines(width: Double, height: Double) async throws {
        let harness = try makeHarness(width: width, height: height)
        defer { harness.dismantle() }
        try await harness.load()
        _ = try await harness.waitForRelocation(after: 0)

        let geometry = try await harness.geometry()
        // The stage is inside the viewer's padding; it can never be wider
        // than the viewport it lives in.
        #expect(geometry.viewerWidth <= geometry.innerWidth + 1)
        #expect(geometry.stageWidth <= geometry.viewerWidth + 1)
        // No horizontal clipping of the outer page.
        let overflow = try await harness.evaluate(
            "document.documentElement.scrollWidth - window.innerWidth"
        ) as? Double
        #expect((overflow ?? 0) <= 1)
        // Baseline behavior: one column, no spread.
        #expect(geometry.renderedDivisor == 1)
    }

    private func jsLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
#endif
