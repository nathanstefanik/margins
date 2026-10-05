import Foundation
import MarginsModel
import Testing

@Suite("ReadingPace")
@MainActor
struct ReadingPaceTests {
    private let suiteName = "ReadingPaceTests-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Produces exactly `count` samples of `interval` seconds: `count + 1`
    /// turns — the first establishes the timestamp (or spans the gap from
    /// a previous batch and is filtered out), the rest land samples.
    private func feed(
        _ pace: ReadingPace, count: Int, interval: TimeInterval = 30,
        base: Date = Date(timeIntervalSince1970: 1_000_000)
    ) {
        var t = base
        for _ in 0...count {
            pace.recordTurn(at: t)
            t += interval
        }
    }

    @Test("turn intervals outside 2–300s are not samples")
    func intervalBounds() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_000_000)

        pace.recordTurn(at: base)  // establishes the timestamp
        pace.recordTurn(at: base + 1.5)  // too fast — skimmed, not read
        pace.recordTurn(at: base + 1.5 + 400)  // too slow — a break
        pace.recordTurn(at: base + 1.5 + 400 + 30)  // a real interval
        #expect(pace.samples == [30])
    }

    @Test("only the newest forty samples are kept")
    func sampleCap() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        feed(pace, count: 50)
        #expect(pace.samples.count == 40)
        // The oldest were dropped: every kept interval is 30s.
        #expect(pace.samples.allSatisfy { $0 == 30 })
    }

    @Test("the estimate is the median, odd and even")
    func medianEstimate() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        // 15 samples: one outlier high, the median still lands mid-pack.
        feed(pace, count: 7, interval: 10)
        feed(pace, count: 7, interval: 60, base: .init(timeIntervalSince1970: 2_000_000))
        feed(pace, count: 1, interval: 200, base: .init(timeIntervalSince1970: 3_000_000))
        // sorted: 7×10, 7×60, 1×200 → median (index 7) = 60
        #expect(pace.secondsPerPage == 60)

        let evenPace = ReadingPace(defaults: defaults)
        evenPace.typographyKey = "reset"  // clears the suite's stored data
        feed(evenPace, count: 8, interval: 10)
        feed(evenPace, count: 8, interval: 60, base: .init(timeIntervalSince1970: 2_000_000))
        // 16 samples → mean of middle two = 35
        #expect(evenPace.secondsPerPage == 35)
    }

    @Test("the estimate stays unknown under fifteen turns")
    func warmupThreshold() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        feed(pace, count: 14)
        #expect(pace.secondsPerPage == nil)
        feed(pace, count: 1)
        #expect(pace.secondsPerPage == 30)
    }

    @Test("a typography change clears the samples")
    func typographyKeyResets() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        pace.typographyKey = "a"
        feed(pace, count: 20)
        #expect(pace.secondsPerPage != nil)

        pace.typographyKey = "b"
        #expect(pace.samples.isEmpty)
        #expect(pace.secondsPerPage == nil)
        // And a turn after the change starts a fresh interval, not one
        // spanning the reflow.
        let base = Date(timeIntervalSince1970: 1_000_000)
        pace.recordTurn(at: base)
        pace.recordTurn(at: base + 30)
        #expect(pace.samples == [30])
    }

    @Test("a jump resets the running interval")
    func jumpResetsInterval() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_000_000)
        pace.recordTurn(at: base)
        pace.noteJump()
        // The turn after the jump measures from the jump, not the turn
        // before it — so this 30s gap yields no sample.
        pace.recordTurn(at: base + 30)
        #expect(pace.samples.isEmpty)
    }

    @Test("samples and key persist across instances")
    func persistence() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        pace.typographyKey = "face=serif"
        feed(pace, count: 20)

        let restored = ReadingPace(defaults: defaults)
        #expect(restored.samples.count == 20)
        #expect(restored.typographyKey == "face=serif")
        #expect(restored.secondsPerPage == 30)
    }

    @Test("display text: last page, sub-minute, minutes, unknown")
    func displayText() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let pace = ReadingPace(defaults: defaults)
        let last = ReaderProgress(page: 20, totalPages: 20)
        // "Last page" is a fact, not an estimate — shown without pace.
        #expect(pace.timeLeftText(for: last) == "Last page")
        #expect(pace.shortTimeLeftText(for: last) == "Last page")

        let early = ReaderProgress(page: 2, totalPages: 20)
        // No pace yet — the footers fall back to the page count.
        #expect(pace.timeLeftText(for: early) == nil)
        #expect(pace.shortTimeLeftText(for: early) == nil)

        // ~9 minutes at 30s/page for 18 pages.
        feed(pace, count: 15, interval: 30)
        #expect(pace.timeLeftText(for: early) == "~9 min left in chapter")
        #expect(pace.shortTimeLeftText(for: early) == "~9 min left")

        // A spread's last page counts as read, and sub-minute reads as <1.
        let fast = ReadingPace(defaults: defaults)
        fast.typographyKey = "other"
        feed(fast, count: 15, interval: 10)
        #expect(fast.timeLeftText(for: ReaderProgress(page: 19, totalPages: 20)) == "<1 min left in chapter")
        #expect(fast.shortTimeLeftText(for: ReaderProgress(page: 18, totalPages: 20, endPage: 19)) == "<1 min left")
    }
}

@Suite("Page-turn predicate")
@MainActor
struct PageTurnPredicateTests {
    @Test("one view forward inside a chapter counts")
    func forwardTurnCounts() {
        let from = ReaderProgress(page: 3, totalPages: 20)
        let to = ReaderProgress(page: 4, totalPages: 20)
        #expect(
            ReaderModel.isPageTurn(from: from, previousChapterIndex: 2, to: to, nextChapterIndex: 2)
        )
    }

    @Test("a spread step counts")
    func spreadTurnCounts() {
        // (3–4) then (5–6): the new start page follows the old end page.
        let from = ReaderProgress(page: 3, totalPages: 20, endPage: 4)
        let to = ReaderProgress(page: 5, totalPages: 20, endPage: 6)
        #expect(
            ReaderModel.isPageTurn(from: from, previousChapterIndex: 2, to: to, nextChapterIndex: 2)
        )
    }

    @Test("page one of the next chapter counts")
    func chapterBoundaryCounts() {
        let from = ReaderProgress(page: 20, totalPages: 20)
        let to = ReaderProgress(page: 1, totalPages: 8)
        #expect(
            ReaderModel.isPageTurn(from: from, previousChapterIndex: 2, to: to, nextChapterIndex: 3)
        )
    }

    @Test("jumps, backwards moves, and chapter skips do not count")
    func jumpsDoNotCount() {
        let three = ReaderProgress(page: 3, totalPages: 20)
        // Backwards.
        #expect(
            !ReaderModel.isPageTurn(
                from: three, previousChapterIndex: 2,
                to: ReaderProgress(page: 2, totalPages: 20), nextChapterIndex: 2)
        )
        // A scrub forward by several pages.
        #expect(
            !ReaderModel.isPageTurn(
                from: three, previousChapterIndex: 2,
                to: ReaderProgress(page: 9, totalPages: 20), nextChapterIndex: 2)
        )
        // A chapter skip landing on page 1.
        #expect(
            !ReaderModel.isPageTurn(
                from: three, previousChapterIndex: 2,
                to: ReaderProgress(page: 1, totalPages: 8), nextChapterIndex: 4)
        )
        // Mid-chapter landing on the next chapter.
        #expect(
            !ReaderModel.isPageTurn(
                from: three, previousChapterIndex: 2,
                to: ReaderProgress(page: 4, totalPages: 8), nextChapterIndex: 3)
        )
        // First relocation after opening — no previous page.
        #expect(
            !ReaderModel.isPageTurn(
                from: nil, previousChapterIndex: nil,
                to: three, nextChapterIndex: 0)
        )
    }
}
