import Foundation
@testable import MarginsCore
import Testing

/// Translated from `crates/margins-core/src/epub_meta.rs`'s test module.
/// Most of these are about where a chapter's *name* comes from: the TOC
/// label, the file's first heading, its `<title>`, or its position — and
/// about the boilerplate that has to be rejected on the way.
@Suite("EpubParser")
struct EpubParserTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the sample EPUB's metadata and chapters parse")
    func parseSampleMetadataAndChapters() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(in: temporaryDirectory())
        let info = try EpubParser.parse(path: epub)

        #expect(info.title == "Sample Book")
        #expect(info.author == "Test Author")
        #expect(info.language == "en")
        #expect(info.chapters.count == 2)
        #expect(info.chapters[0].key == "001")
        #expect(info.chapters[0].title == "Introduction")
        #expect(info.chapters[0].href == "OEBPS/chapter1.xhtml")
        #expect(info.chapters[1].key == "002")
        #expect(info.chapters[1].title == "The Market")
        #expect(info.cover == nil)
    }

    // MARK: Covers

    @Test("an EPUB3 cover-image property is extracted")
    func extractsEpub3Cover() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "epub3.epub", cover: .epub3
        )
        let cover = try #require(try EpubParser.parse(path: epub).cover)
        #expect(cover.fileExtension == "png")
        #expect(cover.bytes == EpubFixtureBuilder.sampleCoverPNG)
    }

    @Test("an EPUB2 meta cover pointer is extracted")
    func extractsEpub2Cover() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "epub2.epub", cover: .epub2
        )
        #expect(try EpubParser.parse(path: epub).cover != nil)
    }

    @Test("a book with no cover marker falls back to the first manifest image")
    func fallsBackToFirstManifestImage() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "bare.epub", cover: .bareImage
        )
        #expect(try EpubParser.parse(path: epub).cover != nil)
    }

    @Test("a cover can be extracted without parsing the spine")
    func extractsCoverWithoutTheSpine() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "backfill.epub", cover: .epub3
        )
        // The library backfill path for books imported before covers existed.
        #expect(EpubParser.extractCover(path: epub)?.fileExtension == "png")
    }

    // MARK: Manifest

    @Test("manifest item attributes parse in either order")
    func manifestAttributesInEitherOrder() throws {
        // bdbbfcd: item attributes are unordered; href-before-id used to
        // drop chapters.
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "mixed-attrs.epub"
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.count == 2)
        #expect(info.chapters[0].href == "OEBPS/chapter1.xhtml")
        #expect(info.chapters[1].href == "OEBPS/chapter2.xhtml")
    }

    // MARK: Table of contents

    @Test("NCX labels and fragments beat document titles")
    func ncxBeatsDocumentTitles() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "ncx.epub", toc: .ncx
        )
        let info = try EpubParser.parse(path: epub)

        // The nested navPoint targets the same file, so the first entry in
        // reading order is the one that names the chapter.
        #expect(info.chapters[0].title == "Opening Remarks")
        #expect(info.chapters[0].fragment == "start")
        #expect(info.chapters[0].href == "OEBPS/chapter1.xhtml")
        #expect(info.chapters[1].title == "Market Day")
        #expect(info.chapters[1].fragment == nil)
    }

    @Test("an EPUB3 nav document supplies titles and fragments")
    func navDocumentSuppliesTitles() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "nav.epub", toc: .nav
        )
        let info = try EpubParser.parse(path: epub)

        // Inline markup inside the anchor is flattened, and the decoy
        // `landmarks` nav (which would have said "Start Reading") loses.
        #expect(info.chapters[0].title == "Opening Remarks")
        #expect(info.chapters[0].fragment == "start")
        #expect(info.chapters[1].title == "Market Day")
        #expect(info.chapters[1].fragment == nil)
    }

    @Test("TOC entries for non-spine files are ignored")
    func nonSpineTOCEntriesIgnored() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "ncx.epub", toc: .ncx
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.count == 2)
        #expect(!info.chapters.contains { $0.title == "Colophon" })
    }

    @Test("a missing TOC leaves chapters without fragments")
    func missingTOCLeavesNoFragments() throws {
        let epub = try EpubFixtureBuilder.sampleEpub(
            in: temporaryDirectory(), named: "plain.epub"
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.allSatisfy { $0.fragment == nil })
        #expect(info.chapters[0].title == "Introduction")
    }

    // MARK: The title chain

    @Test("shared document titles fall back to headings")
    func sharedTitlesFallBackToHeadings() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "shared.epub", bookTitle: "Sample Book",
            chapters: [
                ("A Template", "First Movement"),
                ("A Template", "Second Movement"),
                ("A Template", "Third Movement"),
            ]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.map(\.title) == ["First Movement", "Second Movement", "Third Movement"])
    }

    @Test("two chapters keep a shared document title")
    func twoChaptersKeepASharedTitle() throws {
        // Below the shared-title limit a repeated `<title>` is far more
        // likely to be a real (if unimaginative) name than a template.
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "pair.epub", bookTitle: "Sample Book",
            chapters: [("Shared Name", ""), ("Shared Name", "")]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].title == "Shared Name")
        #expect(info.chapters[1].title == "Shared Name")
    }

    @Test("the book title and Gutenberg boilerplate are never chapter titles")
    func boilerplateIsNeverAChapterTitle() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "boilerplate.epub", bookTitle: "Sample Book",
            chapters: [
                ("Sample Book", "The Opening"),
                ("The Project Gutenberg eBook of Sample Book", "The Closing"),
            ]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].title == "The Opening")
        #expect(info.chapters[1].title == "The Closing")
    }

    @Test("headings are flattened and entities decoded")
    func headingsAreFlattened() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "entities.epub", bookTitle: "Sample Book",
            chapters: [("Sample Book", "Fathers <em>&amp;</em>\n  Sons")]
        )
        #expect(try EpubParser.parse(path: epub).chapters[0].title == "Fathers & Sons")
    }

    @Test("a chapter with no title source falls back to its position")
    func fallsBackToPosition() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "bare.epub", bookTitle: "Sample Book",
            chapters: [("", "")]
        )
        #expect(try EpubParser.parse(path: epub).chapters[0].title == "Chapter 1")
    }

    @Test("a file that is not an EPUB is rejected")
    func rejectsNonEpub() throws {
        let path = try temporaryDirectory().appendingPathComponent("not.epub").path
        try Files.write("not a zip", to: path)
        #expect(throws: CoreError.self) { try EpubParser.parse(path: path) }
    }

    // MARK: Text helpers

    @Test("markup is flattened, entities decoded, whitespace collapsed")
    func cleanTextFlattensMarkup() {
        #expect(EpubParser.cleanText("<em>Fathers</em>\n  &amp;   Sons") == "Fathers & Sons")
        #expect(EpubParser.cleanText("  ") == nil)
        #expect(EpubParser.cleanText("<b></b>") == nil)
        // Numeric references, hex and decimal.
        #expect(EpubParser.cleanText("a &#8212; b &#x2014; c") == "a — b — c")
        // An unknown entity and an unterminated tag are literal text.
        #expect(EpubParser.cleanText("AT&T &unknown; <notclosed") == "AT&T &unknown; <notclosed")
    }

    @Test("in-zip paths normalize for comparison")
    func pathsNormalize() {
        #expect(EpubParser.normalizePath("./OEBPS/a.xhtml") == "OEBPS/a.xhtml")
        #expect(EpubParser.normalizePath("/OEBPS/a.xhtml") == "OEBPS/a.xhtml")
        #expect(EpubParser.percentDecode("OEBPS/a%20b.xhtml") == "OEBPS/a b.xhtml")
        // A TOC src is relative to the document that declared it.
        #expect(EpubParser.resolveRelative("OEBPS/text", "../images/c.xhtml") == "OEBPS/images/c.xhtml")
        #expect(EpubParser.joinHref("OEBPS", "chapter1.xhtml") == "OEBPS/chapter1.xhtml")
        #expect(EpubParser.joinHref("", "chapter1.xhtml") == "chapter1.xhtml")
    }

    @Test("non-content manifest entries are skipped")
    func nonContentEntriesSkipped() {
        #expect(!EpubParser.isProbablyContent("toc.ncx"))
        #expect(!EpubParser.isProbablyContent("OEBPS/nav.xhtml"))
        #expect(!EpubParser.isProbablyContent("cover.png"))
        #expect(EpubParser.isProbablyContent("OEBPS/chapter1.xhtml"))
    }

    // MARK: The real book

    /// Gutenberg's Ebookmaker stamps the book title into every file's
    /// `<title>`, so this fixture only reads correctly when the NCX drives
    /// the chapter names.
    @Test("the Karamazov fixture takes its titles from the NCX")
    func karamazovTitlesComeFromTheNCX() throws {
        let info = try EpubParser.parse(
            path: Fixtures.url("dostoyevsky_the_karamazov_brothers.epub").path
        )

        #expect(info.chapters.count > 50)
        #expect(
            !info.chapters.contains { $0.title.hasPrefix("The Project Gutenberg eBook") },
            "boilerplate <title> leaked into chapter names"
        )
        let first = info.chapters[0].title
        #expect(info.chapters.contains { $0.title != first }, "every chapter got the same title")

        let chapter = try #require(
            info.chapters.first { $0.title == "Chapter II. He Gets Rid Of His Eldest Son" }
        )
        #expect(chapter.fragment == "pgepubid00008")
        #expect(chapter.href.hasSuffix("28054-h-3.htm.html"))
        #expect(!chapter.href.contains("#"))
    }
}
