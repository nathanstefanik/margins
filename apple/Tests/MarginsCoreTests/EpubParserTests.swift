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

    @Test("the manifest's media type and properties drive the content filter")
    func manifestMediaTypeDrivesContentFilter() throws {
        // A chapter named `navarre.xhtml` must survive a filter that used to
        // drop anything with "nav" in the href; an NCX or the nav document
        // itself must not become a chapter.
        func item(
            _ filename: String, mediaType: String? = "application/xhtml+xml",
            properties: String? = nil
        ) -> EpubParser.ManifestItem {
            EpubParser.ManifestItem(
                id: filename, href: filename, mediaType: mediaType, properties: properties
            )
        }
        #expect(EpubParser.isContentItem(item("navarre.xhtml")))
        #expect(!EpubParser.isContentItem(item("toc.ncx", mediaType: "application/x-dtbncx+xml")))
        #expect(!EpubParser.isContentItem(item("nav.xhtml", properties: "nav")))
        // The extension only decides when the manifest omits `media-type`.
        #expect(EpubParser.isContentItem(item("bare.xhtml", mediaType: nil)))
        #expect(!EpubParser.isContentItem(item("style.css", mediaType: nil)))

        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "filter.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(
                    filename: "navarre.xhtml", documentTitle: "Navarre"
                ),
                EpubFixtureBuilder.ChapterSpec(
                    filename: "toc.ncx", mediaType: "application/x-dtbncx+xml"
                ),
                EpubFixtureBuilder.ChapterSpec(filename: "nav.xhtml", properties: "nav"),
            ]
        )
        #expect(try EpubParser.parse(path: epub).chapters.map(\.href) == ["OEBPS/navarre.xhtml"])
    }

    // MARK: Spine

    @Test("linear=no items are skipped without moving keys")
    func linearNoItemsAreSkippedWithoutMovingKeys() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "linear.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "one.xhtml", documentTitle: "One"),
                EpubFixtureBuilder.ChapterSpec(
                    filename: "interlude.xhtml", documentTitle: "Interlude", linear: false
                ),
                EpubFixtureBuilder.ChapterSpec(filename: "two.xhtml", documentTitle: "Two"),
            ]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.map(\.key) == ["001", "003"])
        #expect(info.chapters.map(\.index) == [0, 2])
        #expect(info.chapters.map(\.title) == ["One", "Two"])
    }

    // MARK: Levels

    @Test("NCX nesting sets section levels")
    func ncxNestingSetsLevels() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "nested-ncx.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "part.xhtml", heading: "Part One"),
                EpubFixtureBuilder.ChapterSpec(filename: "chapter.xhtml", heading: "The Chapter"),
            ],
            toc: .ncx([
                .init(
                    "Part One", "part.xhtml",
                    children: [.init("The Chapter", "chapter.xhtml")]
                )
            ])
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].sections == [ChapterSection(title: "Part One", level: 0)])
        #expect(info.chapters[1].sections == [ChapterSection(title: "The Chapter", level: 1)])
        #expect(info.chapters[1].level == 1)
    }

    @Test("nav <ol> nesting sets section levels")
    func navNestingSetsLevels() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "nested-nav.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "part.xhtml", heading: "Part One"),
                EpubFixtureBuilder.ChapterSpec(filename: "book.xhtml", heading: "Book One"),
                EpubFixtureBuilder.ChapterSpec(filename: "chapter.xhtml", heading: "Chapter One"),
            ],
            toc: .nav([
                .init(
                    "Part One", "part.xhtml",
                    children: [
                        .init(
                            "Book One", "book.xhtml",
                            children: [.init("Chapter One", "chapter.xhtml#c1")]
                        )
                    ]
                )
            ])
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].sections == [ChapterSection(title: "Part One", level: 0)])
        #expect(info.chapters[1].sections == [ChapterSection(title: "Book One", level: 1)])
        #expect(
            info.chapters[2].sections == [
                ChapterSection(title: "Chapter One", fragment: "c1", level: 2)
            ]
        )
    }

    @Test("a flat NCX gets levels inferred from its labels")
    func flatNcxLevelsAreInferredFromLabels() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "flat-ncx.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "cover.xhtml", heading: "Cover"),
                EpubFixtureBuilder.ChapterSpec(filename: "part.xhtml", heading: "PART I"),
                EpubFixtureBuilder.ChapterSpec(filename: "book.xhtml", heading: "Book I. A Family"),
                EpubFixtureBuilder.ChapterSpec(filename: "chapter.xhtml", heading: "Chapter I. Arriving"),
            ],
            toc: .ncx([
                .init("Cover", "cover.xhtml"),
                .init("PART I", "part.xhtml"),
                .init("Book I. A Family", "book.xhtml"),
                .init("Chapter I. Arriving", "chapter.xhtml"),
            ])
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.map(\.level) == [0, 0, 1, 2])
        #expect(info.chapters.map(\.matter) == [.cover, .body, .body, .body])
    }

    @Test("every TOC entry for a file becomes a section")
    func everyTocEntryInAFileBecomesASection() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "multi-entry.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "book.xhtml", heading: "BOOK ONE")
            ],
            toc: .ncx([
                .init("Book I", "book.xhtml#book"),
                .init("Chapter I", "book.xhtml#ch1"),
                .init("Chapter II", "book.xhtml#ch2"),
            ])
        )
        let info = try EpubParser.parse(path: epub)
        let chapter = info.chapters[0]
        #expect(chapter.title == "Book I")
        #expect(chapter.fragment == "book")
        #expect(chapter.sections.map(\.title) == ["Book I", "Chapter I", "Chapter II"])
        #expect(chapter.sections.map(\.fragment) == ["book", "ch1", "ch2"])
        #expect(chapter.sections.map(\.level) == [0, 1, 1])
    }

    // MARK: Cover and classification

    @Test("quotes around a whole title are stripped")
    func titleQuotesAreStripped() {
        #expect(EpubParser.cleanText("\"Cover\"") == "Cover")
        #expect(EpubParser.cleanText("\u{201C}Cover\u{201D}") == "Cover")
        // Quotes inside a title, or on one side only, are meaning, not
        // wrapping punctuation.
        #expect(EpubParser.cleanText("\"A\" and \"B\"") == "\"A\" and \"B\"")
        #expect(EpubParser.cleanText("\"Cover") == "\"Cover")
    }

    @Test("a near-empty page with an image is a cover")
    func coverWrapperIsDetectedByShape() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "wrapper.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(
                    filename: "wrap.xhtml", documentTitle: "\"Cover\"",
                    markedUpBody: #"<div><img src="cover.png" alt=""/></div>"#
                ),
                EpubFixtureBuilder.ChapterSpec(
                    filename: "chapter.xhtml", documentTitle: "Chapter One",
                    body: "A real chapter of readable text that is clearly not a cover page."
                ),
            ]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].title == "Cover")
        #expect(info.chapters[0].matter == .cover)
        #expect(info.chapters[1].matter == .body)
    }

    @Test("a bodymatter landmark outranks a front-looking title")
    func landmarksBodymatterWinsOverTitleHeuristics() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "landmarks.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "intro.xhtml", heading: "Introduction"),
                EpubFixtureBuilder.ChapterSpec(filename: "chapter.xhtml", heading: "Chapter One"),
            ],
            toc: .nav([
                .init("Introduction", "intro.xhtml"),
                .init("Chapter One", "chapter.xhtml"),
            ]),
            landmarks: [(type: "bodymatter", href: "intro.xhtml")]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].matter == .body)
        #expect(info.chapters[1].matter == .body)
    }

    @Test("a guide text reference starts Body")
    func guideTextReferenceStartsBody() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "guide.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(filename: "intro.xhtml", heading: "Introduction"),
                EpubFixtureBuilder.ChapterSpec(filename: "chapter.xhtml", heading: "Chapter One"),
            ],
            guide: [(type: "text", href: "intro.xhtml")]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters[0].matter == .body)
    }

    @Test("a document's own epub:type classifies it")
    func documentEpubTypeClassifies() throws {
        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "doctype.epub",
            chapters: [
                EpubFixtureBuilder.ChapterSpec(
                    filename: "front.xhtml", heading: "A Strange Name", epubType: "frontmatter"
                ),
                EpubFixtureBuilder.ChapterSpec(
                    filename: "body.xhtml", heading: "Introduction", epubType: "bodymatter"
                ),
                EpubFixtureBuilder.ChapterSpec(
                    filename: "back.xhtml", heading: "After All That", epubType: "backmatter"
                ),
            ]
        )
        let info = try EpubParser.parse(path: epub)
        #expect(info.chapters.map(\.matter) == [.front, .body, .back])
    }

    @Test("the Oxford front-matter run is classified around the Part/Book file")
    func oxfordStyleFrontMatterIsClassified() throws {
        let frontTitles = [
            "Cover", "Half Title", "Series Page", "Title Page", "Copyright",
            "Dedication", "Acknowledgements", "Contents", "Introduction",
            "Translator's Note", "Texts Used", "Select Bibliography",
            "Chronology", "Principal Characters", "From the Author",
            "A Note on the Text",
        ]
        var chapters = frontTitles.enumerated().map { index, title in
            EpubFixtureBuilder.ChapterSpec(
                filename: "front\(index).xhtml", documentTitle: title, heading: title
            )
        }
        chapters.append(EpubFixtureBuilder.ChapterSpec(filename: "part.xhtml", heading: "Part One"))
        chapters.append(
            EpubFixtureBuilder.ChapterSpec(
                filename: "ch1.xhtml", heading: "1. Fyodor Pavlovich Karamazov"
            )
        )
        chapters.append(EpubFixtureBuilder.ChapterSpec(filename: "ch2.xhtml", heading: "2. The Old Buffoon"))
        chapters.append(EpubFixtureBuilder.ChapterSpec(filename: "ch3.xhtml", heading: "3. The Women"))
        chapters.append(EpubFixtureBuilder.ChapterSpec(filename: "notes.xhtml", heading: "Explanatory Notes"))
        chapters.append(EpubFixtureBuilder.ChapterSpec(filename: "index.xhtml", heading: "Index"))

        let epub = try EpubFixtureBuilder.epub(
            in: temporaryDirectory(), named: "oxford.epub",
            bookTitle: "The Brothers Karamazov",
            chapters: chapters,
            toc: .nav([
                .init(
                    "Part One", "part.xhtml",
                    children: [
                        .init(
                            "Book One: The Story of a Family", "part.xhtml",
                            children: [
                                .init("1. Fyodor Pavlovich Karamazov", "ch1.xhtml#c1"),
                                .init("2. The Old Buffoon", "ch2.xhtml#c2"),
                                .init("3. The Women", "ch3.xhtml#c3"),
                            ]
                        )
                    ]
                )
            ])
        )
        let info = try EpubParser.parse(path: epub)
        let chaptersByKey = Dictionary(uniqueKeysWithValues: info.chapters.map { ($0.key, $0) })

        #expect(chaptersByKey["001"]?.matter == .cover)
        for key in (2...16).map({ String(format: "%03d", $0) }) {
            #expect(chaptersByKey[key]?.matter == .front, "key \(key) should be front matter")
        }
        // Part One and Book One share one file: two sections, two outline
        // levels, one Body chapter.
        let part = try #require(chaptersByKey["017"])
        #expect(part.matter == .body)
        #expect(part.level == 0)
        #expect(part.sections.map(\.title) == ["Part One", "Book One: The Story of a Family"])
        #expect(part.sections.map(\.level) == [0, 1])
        #expect(chaptersByKey["018"]?.matter == .body)
        #expect(chaptersByKey["018"]?.level == 2)
        #expect(chaptersByKey["021"]?.matter == .back)
        #expect(chaptersByKey["022"]?.matter == .back)
    }

    @Test("the title heuristic lists classify their own vocabularies")
    func titleHeuristicsClassifyFrontAndBackMatter() {
        for title in EpubParser.frontMatterTitles {
            #expect(
                EpubParser.frontMatter(title.capitalized, bookTitle: "Some Book") == .front,
                Comment(rawValue: title)
            )
        }
        for title in EpubParser.backMatterTitles {
            #expect(EpubParser.backMatter(title.capitalized) == .back, Comment(rawValue: title))
        }
        // Whole-string or prefix-before-non-letter only.
        #expect(EpubParser.backMatter("Notes on the Text") == .back)
        #expect(EpubParser.backMatter("Notebook") == nil)
        #expect(EpubParser.frontMatter("Introductions", bookTitle: "Some Book") == nil)
        // The book's own title and an all-caps series name are front matter.
        #expect(EpubParser.frontMatter("Some Book", bookTitle: "Some Book") == .front)
        #expect(EpubParser.frontMatter("OXFORD WORLD'S CLASSICS", bookTitle: "Some Book") == .front)
        // Prologue is never front matter by title.
        #expect(EpubParser.frontMatter("Prologue", bookTitle: "Some Book") == nil)
        // A structural label is Body regardless of the title lists.
        #expect(EpubParser.isStructuralLabel("Chapter I. Arriving"))
        #expect(EpubParser.isStructuralLabel("PART TWO"))
        #expect(EpubParser.isStructuralLabel("2. The Old Buffoon"))
        #expect(EpubParser.isStructuralLabel("IV. The Fourth"))
        #expect(!EpubParser.isStructuralLabel("Mitya"))
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

    @Test("the Karamazov fixture gets a clean outline")
    func karamazovFixtureOutline() throws {
        let info = try EpubParser.parse(
            path: Fixtures.url("dostoyevsky_the_karamazov_brothers.epub").path
        )
        let byKey = Dictionary(uniqueKeysWithValues: info.chapters.map { ($0.key, $0) })

        // 001: the image wrapper, titled from `"Cover"` with quotes stripped.
        #expect(byKey["001"]?.matter == .cover)
        #expect(byKey["001"]?.title == "Cover")
        // 002: Gutenberg's boilerplate header is front matter.
        #expect(byKey["002"]?.matter == .front)

        // 003 holds PART I and Book I; both survive as sections.
        let part = try #require(byKey["003"])
        #expect(part.matter == .body)
        #expect(part.title == "PART I")
        #expect(part.sections.map(\.title) == ["PART I", "Book I. The History Of A Family"])
        #expect(part.sections.map(\.level) == [0, 1])

        // 009 holds Book II and its first chapter.
        let bookTwo = try #require(byKey["009"])
        #expect(bookTwo.matter == .body)
        #expect(
            bookTwo.sections.map(\.title)
                == ["Book II. An Unfortunate Gathering", "Chapter I. They Arrive At The Monastery"]
        )
        #expect(bookTwo.sections.map(\.level) == [1, 2])

        // Every one of the NCX's 96 chapter labels survives as a Body section.
        let chapterSections = info.chapters
            .filter { $0.matter == .body }
            .flatMap(\.sections)
            .filter { $0.title.hasPrefix("Chapter ") }
        #expect(chapterSections.count == 96)

        #expect(byKey["100"]?.matter == .back)
        #expect(byKey["100"]?.title == "FOOTNOTES")
        #expect(!info.chapters.contains { $0.title.hasPrefix("The Project Gutenberg eBook") })
    }
}
