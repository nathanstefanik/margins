import Foundation
import Testing

@testable import MarginsCore

/// The pure XHTML → passage side of extraction (epub-level coverage comes
/// with the index tests).
@Suite("Text extraction")
struct TextExtractTests {
    private func passages(_ document: String) -> [String] {
        TextExtractor.passages(fromDocument: document)
    }

    @Test("block elements split the body into passages")
    func blockBoundaries() {
        let document = """
            <html><body>
            <h1>The Title</h1>
            <p>First paragraph.</p><div>Inside a div.</div>
            <ul><li>one</li><li>two</li></ul>
            <h2>Section</h2><p>Third.</p>
            </body></html>
            """
        #expect(
            passages(document) == [
                "The Title", "First paragraph.", "Inside a div.",
                "one", "two", "Section", "Third.",
            ])
    }

    @Test("<br> is a space inside the passage, not a boundary")
    func brIsASpace() {
        #expect(
            passages("<body><p>line one<br>line two<br/>line three</p></body>")
                == ["line one line two line three"])
    }

    @Test("nested blocks never duplicate text")
    func nestedBlocks() {
        let document = """
            <body><div><div><p>nested words</p></div></div>
            <blockquote><p>quoted</p></blockquote></body>
            """
        #expect(passages(document) == ["nested words", "quoted"])
    }

    @Test("script, style, head, title, and svg content is dropped")
    func skippedElements() {
        let document = """
            <html><head><title>The Page Name</title>
            <style>p { color: red }</style></head>
            <body><p>visible</p>
            <script>var s = "invisible";</script>
            <svg><text>also invisible</text></svg>
            </body></html>
            """
        #expect(passages(document) == ["visible"])
    }

    @Test("entities decode — HTML4 names, decimal, and hex")
    func entities() {
        #expect(
            passages("<p>&eacute; &mdash; &#8217; &#x2019; &laquo; &szlig; &copy;</p>")
                == ["é — ’ ’ « ß ©"])
    }

    @Test("unknown entities stay literal")
    func unknownEntities() {
        #expect(passages("<p>a &foo; b &bar c</p>") == ["a &foo; b &bar c"])
    }

    @Test("the pre-HTML4 names still decode in any case")
    func legacyCaselessEntities() {
        #expect(
            passages("<p>a &AMP; b &LT;tag&GT; &MDASH; &NBSP;z</p>")
                == ["a & b <tag> — z"])
        // But the fallback is a closed set — case still matters elsewhere.
        #expect(passages("<p>&EACUTE;</p>") == ["&EACUTE;"])
    }

    @Test("whitespace collapses and paragraphs are trimmed")
    func whitespaceCollapse() {
        #expect(
            passages("<p>a\n   b\t\tc  \n d</p>") == ["a b c d"])
    }

    @Test("empty and tokenless paragraphs drop")
    func emptyDropped() {
        let document = "<body><p>   </p><p>&nbsp;</p><p>—…</p><p>real</p></body>"
        #expect(passages(document) == ["real"])
    }

    @Test("inline markup joins words, it does not split them")
    func inlineJoins() {
        #expect(
            passages("<p>un<i>for</i>gettable <em>thing</em></p>")
                == ["unforgettable thing"])
    }

    @Test("a document without a body is still extracted")
    func bodyFallback() {
        #expect(passages("<p>no body wrapper</p>") == ["no body wrapper"])
    }

    @Test("a long paragraph splits at sentence ends into ≤ ~800-char chunks")
    func longSplit() {
        // Sentences of ~120 characters; ~3 000 characters in all.
        let sentence =
            "Sentence number that runs long enough to matter for the chunking logic of the extractor body."
        let document =
            "<p>" + (0..<30).map { "\(sentence) \($0)." }.joined(separator: " ")
            + "</p>"
        let chunks = passages(document)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.count <= 850 })
        // Every boundary is a sentence end — only the final chunk lacks
        // the terminal punctuation when the paragraph ends mid-flow, and
        // here every sentence ends with a full stop.
        #expect(chunks.allSatisfy { $0.hasSuffix(".") })
        #expect(chunks.joined(separator: " ").count == document.count - 7)
    }

    @Test("one overlong sentence stays whole")
    func singleSentenceWhole() {
        let sentence = String(repeating: "word ", count: 299) + "end"
        #expect(sentence.count > TextExtractor.splitThreshold)
        #expect(passages("<p>\(sentence)</p>") == [sentence])
    }
}
