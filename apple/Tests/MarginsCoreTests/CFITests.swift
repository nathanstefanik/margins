import Foundation
@testable import MarginsCore
import Testing

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
}
