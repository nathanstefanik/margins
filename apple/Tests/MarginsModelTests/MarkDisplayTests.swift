import Testing
import Foundation
import MarginsCore
import MarginsModel

@Suite("MarkDisplay")
struct MarkDisplayTests {
    /// 2026-09-05T14:02:11Z.
    private static let markDate = Date(timeIntervalSince1970: 1_788_616_931)

    private func mark(id: String, percent: Double?, cfi: String?) -> Mark {
        Mark(
            id: id,
            cfi: cfi,
            at: Self.markDate,
            percent: percent,
            quote: "quote",
            body: "body"
        )
    }

    @Test("attribution renders percent with one decimal and the date")
    func attributionWithPercent() {
        let text = MarkDisplay.attribution(percent: 38.2, at: Self.markDate)
        #expect(text == "38.2% · Sep 5, 2026")
    }

    @Test("attribution falls back to date only without a percent")
    func attributionWithoutPercent() {
        let text = MarkDisplay.attribution(percent: nil, at: Self.markDate)
        #expect(text == "Sep 5, 2026")
    }

    @Test("attribution with neither percent nor date is empty")
    func attributionEmpty() {
        #expect(MarkDisplay.attribution(percent: nil, at: nil) == "")
    }

    @Test("count text pluralizes")
    func countText() {
        #expect(MarkDisplay.countText(0) == "0 marks")
        #expect(MarkDisplay.countText(1) == "1 mark")
        #expect(MarkDisplay.countText(3) == "3 marks")
    }

    @Test("display order: percent ascending, page-anchored last, then cfi and id")
    func sortedForDisplay() {
        let marks = [
            mark(id: "ddddddddddd", percent: nil, cfi: nil),
            mark(id: "ccccccccccc", percent: 51.0, cfi: "epubcfi(/6/4)"),
            mark(id: "aaaaaaaaaaa", percent: 38.2, cfi: "epubcfi(/6/2)"),
            mark(id: "bbbbbbbbbbb", percent: 51.0, cfi: "epubcfi(/6/3)"),
        ]
        let ids = MarkDisplay.sortedForDisplay(marks).map(\.id)
        #expect(ids == ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc", "ddddddddddd"])
    }
}
