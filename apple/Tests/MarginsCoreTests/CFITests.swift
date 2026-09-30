import Foundation
import Testing

@testable import MarginsCore

/// `CFI.swift` is intentionally partial: it exists so the club view can
/// decide whether two members marked the same passage. These tests pin the
/// supported forms and the fail-to-nil posture for everything else.
@Suite("CFI")
struct CFITests {
    @Test("a point CFI parses to its element and offset")
    func pointParses() throws {
        let range = try #require(CFI.parse("epubcfi(/6/4!/4/2/1:0)"))
        #expect(range.element == [6, 4, 4, 2, 1])
        #expect(range.startOffset == 0)
        #expect(range.endOffset == 0)
    }

    @Test("a range CFI pulls the parent path into the element")
    func rangeParses() throws {
        let range = try #require(CFI.parse("epubcfi(/6/14!/4/2/10,/1:0,/1:42)"))
        #expect(range.element == [6, 14, 4, 2, 10, 1])
        #expect(range.startOffset == 0)
        #expect(range.endOffset == 42)
    }

    @Test("assertions are stripped from the path")
    func assertionsAreStripped() throws {
        let range = try #require(CFI.parse("epubcfi(/6/4[chap01]!/4[body01]/2)"))
        #expect(range.element == [6, 4, 4, 2])
        #expect(range.startOffset == nil)
        #expect(range.endOffset == nil)
    }

    @Test("malformed CFIs return nil")
    func malformedReturnsNil() {
        #expect(CFI.parse("") == nil)
        #expect(CFI.parse("not a cfi") == nil)
        #expect(CFI.parse("epubcfi(") == nil)
        #expect(CFI.parse("epubcfi(a/b)") == nil)
        #expect(CFI.parse("epubcfi(/6/4!/4/2,)") == nil)
        // A range that spans different elements cannot cluster.
        #expect(CFI.parse("epubcfi(/6/4,/2/1:0,/4/1:5)") == nil)
    }

    @Test("overlapping offsets in one element overlap")
    func offsetOverlap() throws {
        let a = try #require(CFI.parse("epubcfi(/6/4!/4/2/10,/1:0,/1:42)"))
        let b = try #require(CFI.parse("epubcfi(/6/4!/4/2/10,/1:10,/1:50)"))
        let touching = try #require(CFI.parse("epubcfi(/6/4!/4/2/10,/1:50,/1:80)"))
        let apart = try #require(CFI.parse("epubcfi(/6/4!/4/2/10,/1:60,/1:90)"))

        #expect(CFI.overlaps(a, b))
        #expect(CFI.overlaps(b, a))
        #expect(CFI.overlaps(b, touching))
        #expect(!CFI.overlaps(a, apart))
    }

    @Test("an element selection overlaps content inside it")
    func ancestorOverlap() throws {
        let element = try #require(CFI.parse("epubcfi(/6/4!/4/2)"))
        let point = try #require(CFI.parse("epubcfi(/6/4!/4/2/1:0)"))
        let sibling = try #require(CFI.parse("epubcfi(/6/4!/4/3/1:0)"))

        #expect(CFI.overlaps(element, point))
        #expect(CFI.overlaps(point, element))
        #expect(!CFI.overlaps(element, sibling))
    }

    @Test("an element selection overlaps a range in the same element")
    func elementSelectionOverlapsSameElement() throws {
        let element = try #require(CFI.parse("epubcfi(/6/4!/4/2/10)"))
        let range = try #require(CFI.parse("epubcfi(/6/4!/4/2/10,/1:0,/1:42)"))
        #expect(CFI.overlaps(element, range))
        #expect(CFI.overlaps(range, element))
    }

    @Test("unrelated paths do not overlap")
    func unrelatedPaths() throws {
        let a = try #require(CFI.parse("epubcfi(/6/4!/4/2/10,/1:0,/1:42)"))
        let b = try #require(CFI.parse("epubcfi(/6/4!/4/8/2,/1:0,/1:42)"))
        #expect(!CFI.overlaps(a, b))
    }

    @Test("point CFIs order by base, then document steps, then offset")
    func pointOrdering() {
        #expect(
            CFI.comparePoints("epubcfi(/6/2!/4/2)", "epubcfi(/6/4!/4/2)")
                == .orderedAscending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/4/2/10)", "epubcfi(/6/4!/4/2/2)")
                == .orderedDescending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/10!/4)", "epubcfi(/6/4!/4)")
                == .orderedDescending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2/1:5)")
                == .orderedAscending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/4/2)", "epubcfi(/6/4!/4/2/1:0)")
                == .orderedAscending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/4/2/1:0)", "epubcfi(/6/4!/4/2/1:0)")
                == .orderedSame
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/4/2/1)", "epubcfi(/6/4!/4/2/1:0)")
                == .orderedSame
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4)", "epubcfi(/6/4!/4/2/1:0)")
                == .orderedAscending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/8!/4/2)", "epubcfi(/6/4!/4/2)")
                == .orderedDescending
        )
    }

    @Test("the base path is not flattened into the document path")
    func basePathIsNotFlattened() {
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/8)", "epubcfi(/6/4/2!/1)")
                == .orderedAscending
        )
        #expect(
            CFI.comparePoints("epubcfi(/6/4!/4/2)", "epubcfi(/6/6!/4/2/1:0)")
                == .orderedAscending
        )
    }

    @Test("assertions and side bias do not change a point's identity")
    func assertionsDoNotAffectOrdering() {
        #expect(
            CFI.comparePoints(
                "epubcfi(/6/4[chap01]!/4[body01]/2/1:0)",
                "epubcfi(/6/4!/4/2/1:0)"
            ) == .orderedSame
        )
        #expect(
            CFI.comparePoints(
                "epubcfi(/6/4!/4/2/1[some-id]:3)",
                "epubcfi(/6/4!/4/2/1:3)"
            ) == .orderedSame
        )
        for assertion in ["a^]b", "a^,b", "a^!b", "a^:b", "a,b"] {
            #expect(
                CFI.comparePoints(
                    "epubcfi(/6/4!/4/2[\(assertion)]/1:0)",
                    "epubcfi(/6/4!/4/2/1:0)"
                ) == .orderedSame,
                "assertion \(assertion)"
            )
        }
        #expect(
            CFI.comparePoints(
                "epubcfi(/6/4!/4/2/1:0;s=a)",
                "epubcfi(/6/4!/4/2/1:0)"
            ) == .orderedSame
        )
        #expect(
            CFI.comparePoints(
                "epubcfi(/6/4!/4/2/1:0;s=b)",
                "epubcfi(/6/4!/4/2/1:0)"
            ) == .orderedSame
        )
    }

    @Test("a text assertion after the offset does not change identity")
    func textAssertionAfterOffset() {
        let bare = "epubcfi(/6/4!/4/2/1:3)"
        let equivalents = [
            "epubcfi(/6/4!/4/2/1:3[before,after])",
            "epubcfi(/6/4!/4/2/1:3[first^,second^]x])",
            "epubcfi(/6/4!/4/2/1:3[note;s=b])",
            "epubcfi(/6/4!/4/2/1:3[note];s=b)",
            "epubcfi(/6/4!/4/2/1[a]:3[note];s=a)",
            "epubcfi(/6/4!/4/2/1[a][b]:3[x][y])",
        ]
        for variant in equivalents {
            #expect(
                CFI.comparePoints(variant, bare) == .orderedSame, "\(variant)")
            #expect(
                CFI.comparePoints(bare, variant) == .orderedSame, "\(variant)")
        }
    }

    @Test("an unescaped nested bracket inside an assertion is malformed")
    func nestedAssertionBracketsAreMalformed() {
        let malformed = [
            "epubcfi(/6/4!/4/2/1[a[b]c]/1:0)",
            "epubcfi(/6/4!/4/2/1:3[a[b]c])",
            "epubcfi(/6/4!/4/2[a[[b]]/1:0)",
            "epubcfi(/6/4!/4/2/1[a[b]/1:0)",
            "epubcfi(/6/4!/4/2/1[a^:[b]/1:0)",
        ]
        let good = "epubcfi(/6/4!/4/2/1:0)"
        for raw in malformed {
            #expect(CFI.comparePoints(raw, good) == nil, "\(raw)")
            #expect(CFI.comparePoints(good, raw) == nil, "\(raw)")
        }
        #expect(
            CFI.comparePoints(
                "epubcfi(/6/4!/4/2/1[a^[b^]c]:0)", good) == .orderedSame
        )
    }

    @Test("non-point and malformed CFIs have no order")
    func nonPointsReturnNil() {
        let malformed = [
            "",
            "not a cfi",
            "epubcfi(",
            "epubcfi()",
            "epubcfi(/6/4!)",
            "epubcfi(!/4/2)",
            "epubcfi(/6/4!/4/2,/1:0,/1:5)",
            "epubcfi(/6/4!/4/2/1:-1)",
            "epubcfi(/6/4!/4/2/1:)",
            "epubcfi(/6/4!/4/2[abc/1:0)",
            "epubcfi(/6/4!/4/2]1:0)",
            "epubcfi(/6/4!/4/2!/1)",
            "epubcfi(/6/4!/4/2~5)",
            "epubcfi(/6/4!/4/2@3)",
            "epubcfi(/6/4!/4/2/1:0;s=c)",
            "epubcfi(/0/4!/4/2)",
            "epubcfi(/6/4!/4/2/1:0/3)",
            "epubcfi(/6/4!/4/2//1:0)",
        ]
        for raw in malformed {
            #expect(
                CFI.comparePoints(raw, "epubcfi(/6/4!/4/2/1:0)") == nil, "\(raw)")
            #expect(
                CFI.comparePoints("epubcfi(/6/4!/4/2/1:0)", raw) == nil, "\(raw)")
        }
    }
}
