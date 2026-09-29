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
