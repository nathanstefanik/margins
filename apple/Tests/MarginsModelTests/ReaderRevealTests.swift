#if os(macOS)
import Foundation
import Testing

@testable import MarginsModel

/// `readerRevealText` end-to-end: the real reader page walks the rendered
/// section, normalizes typographic noise (curly quotes, soft hyphens,
/// zero-width spaces), and reports a CFI back through `readerPost`.
@Suite("Reader reveal", .serialized)
struct ReaderRevealTests {
    /// A needle matching p-noisy through its noise: the doc has “don’t”
    /// (curly), “your­self” (soft hyphen), and “who​lies” (ZWSP) — the
    /// needle's straight apostrophe and dropped joiners still match.
    private static let needle =
        "Above all, don't lie to yourself — the man wholies to himself "
        + "and listens to his own lie comes to a point where he cannot "
        + "distinguish the truth."

    @Test("reveal finds the passage and reports a CFI")
    @MainActor
    func revealFinds() async throws {
        let harness = try ReaderLayoutHarness(
            fixture: .reveal, viewport: CGSize(width: 800, height: 900))
        defer { harness.dismantle() }
        try await harness.load(chapter: "ch1.xhtml")
        try await harness.waitForLayoutSettled()

        let literal = String(
            data: try JSONEncoder().encode(Self.needle), encoding: .utf8)!
        _ = try await harness.evaluate("readerRevealText(\(literal)); \"sent\"")
        let message = try await harness.waitForMessage("revealed", "reveal result")
        #expect(message["found"] as? Bool == true)
        #expect((message["cfi"] as? String)?.isEmpty == false)
    }

    @Test("a needle crossing a <br/> still matches")
    @MainActor
    func revealAcrossLineBreaks() async throws {
        let harness = try ReaderLayoutHarness(
            fixture: .reveal, viewport: CGSize(width: 800, height: 900))
        defer { harness.dismantle() }
        try await harness.load(chapter: "ch1.xhtml")
        try await harness.waitForLayoutSettled()

        // The verse is one <p> split by <br/>: the walk's text nodes join
        // as "…hearts.theonlyhard…" so the space-carrying needle can only
        // match on the whitespace-stripped form.
        let literal = String(
            data: try JSONEncoder().encode(
                "grow your hearts the only hard work is to kneel"),
            encoding: .utf8)!
        _ = try await harness.evaluate("readerRevealText(\(literal)); \"sent\"")
        let message = try await harness.waitForMessage("revealed", "reveal across <br/>")
        #expect(message["found"] as? Bool == true)
        #expect((message["cfi"] as? String)?.isEmpty == false)
    }

    @Test("fixture startup surfaces a book-open failure")
    @MainActor
    func fixtureStartupRejectsBookFailure() async throws {
        let harness = try ReaderLayoutHarness(
            fixture: .reveal,
            viewport: CGSize(width: 800, height: 900),
            startupScript: """
                (function() {
                  var fetch = window.fetch.bind(window);
                  window.fetch = function(resource, options) {
                    if (String(resource).indexOf('book.epub') !== -1) {
                      return Promise.reject(new Error('injected fixture fetch failure'));
                    }
                    return fetch(resource, options);
                  };
                })();
                """
        )
        defer { harness.dismantle() }
        await #expect(throws: ReaderLayoutHarnessError.self) {
            try await harness.load()
        }
        #expect(harness.consoleTail().contains { $0.contains("injected fixture fetch failure") })
    }

    @Test("fixture load returns only after the book is rendered")
    @MainActor
    func fixtureLoadIsReady() async throws {
        let harness = try ReaderLayoutHarness(
            fixture: .reveal, viewport: CGSize(width: 800, height: 900))
        defer { harness.dismantle() }
        try await harness.load()
        #expect(try await harness.evaluate("readerOpened") as? Bool == true)
        #expect(try await harness.visibleParagraphIDs().isEmpty == false)
    }

    /// Marks and the reveal flash share the `margins-highlight` /
    /// `margins-reveal` rules emitted per paper: the epub.js <g> gets the
    /// theme's fill and blend, and a `readerSetTheme` restyles nodes that
    /// are already on the page because the look lives in the keyed
    /// stylesheet, not on the elements.
    @Test("highlights take the paper's fill and restyle on theme change")
    @MainActor
    func highlightsFollowTheme() async throws {
        let harness = try ReaderLayoutHarness(
            fixture: .reveal, viewport: CGSize(width: 800, height: 900))
        defer { harness.dismantle() }
        try await harness.load(chapter: "ch1.xhtml")
        try await harness.waitForLayoutSettled()

        let cfi = try #require(
            try await harness.evaluate("readerCurrentCfi()") as? String)
        let cfiLiteral = String(
            data: try JSONEncoder().encode(cfi), encoding: .utf8)!
        _ = try await harness.evaluate("readerHighlight(\(cfiLiteral)); \"sent\"")

        func fillAndBlend() async throws -> (String?, String?) {
            let fill = try await harness.evaluate(
                "getComputedStyle(document.querySelector('g.margins-highlight')).fill")
                as? String
            let blend = try await harness.evaluate(
                "getComputedStyle(document.querySelector('g.margins-highlight')).mixBlendMode")
                as? String
            return (fill, blend)
        }

        var (fill, blend) = try await fillAndBlend()
        #expect(fill?.contains("255, 213, 79") == true)
        #expect(blend == "multiply")

        _ = try await harness.evaluate("readerSetTheme(\"night\"); \"sent\"")
        (fill, blend) = try await fillAndBlend()
        #expect(fill?.contains("190, 150, 80") == true)
        #expect(blend == "normal")
    }

    @Test("a needle absent from the chapter reports found:false")
    @MainActor
    func revealMisses() async throws {
        let harness = try ReaderLayoutHarness(
            fixture: .reveal, viewport: CGSize(width: 800, height: 900))
        defer { harness.dismantle() }
        try await harness.load(chapter: "ch1.xhtml")
        try await harness.waitForLayoutSettled()

        let literal = String(
            data: try JSONEncoder().encode(
                "completely absent text never printed in the fixture"),
            encoding: .utf8)!
        _ = try await harness.evaluate("readerRevealText(\(literal)); \"sent\"")
        let message = try await harness.waitForMessage("revealed", "reveal miss")
        #expect(message["found"] as? Bool == false)
    }
}
#endif
