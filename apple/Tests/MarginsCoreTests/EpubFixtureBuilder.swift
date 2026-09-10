import Foundation
import ZIPFoundation

/// Builds minimal EPUBs in memory, translated from
/// `crates/margins-core/src/test_fixtures.rs`. The labels in each TOC
/// deliberately differ from the chapters' `<title>` tags so a test can tell
/// which source a title came from.
enum EpubFixtureBuilder {
    /// Which cover declaration the sample EPUB should carry.
    enum SampleCover {
        /// No cover at all.
        case none
        /// EPUB3: manifest item with `properties="cover-image"`.
        case epub3
        /// EPUB2: `<meta name="cover" content="…"/>` pointing at the item.
        case epub2
        /// No cover marker: only an image item in the manifest.
        case bareImage
    }

    /// Which table of contents the sample EPUB should carry.
    enum SampleTOC {
        /// No nav document and no NCX.
        case none
        /// EPUB2 NCX, with a nested navPoint and an entry for a non-spine file.
        case ncx
        /// EPUB3 nav document, with a decoy `landmarks` nav before the TOC.
        case nav
    }

    /// A valid 1x1 PNG (red pixel), small enough to embed in tests.
    static let sampleCoverPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8,
        0xCF, 0xC0, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    /// A minimal valid-enough EPUB with two chapters.
    static func sampleEpub(
        in directory: URL,
        named filename: String = "sample.epub",
        cover: SampleCover = .none,
        toc: SampleTOC = .none
    ) throws -> String {
        let coverItem: String
        switch cover {
        case .none: coverItem = ""
        case .epub3:
            coverItem = #"    <item href="cover.png" id="cover" media-type="image/png" properties="cover-image"/>"# + "\n"
        case .epub2, .bareImage:
            coverItem = #"    <item href="cover.png" id="cover" media-type="image/png"/>"# + "\n"
        }
        let coverMeta = cover == .epub2
            ? #"    <meta name="cover" content="cover"/>"# + "\n"
            : ""
        let tocItem: String
        switch toc {
        case .none: tocItem = ""
        case .ncx:
            tocItem = #"    <item href="toc.ncx" id="ncx" media-type="application/x-dtbncx+xml"/>"# + "\n"
        case .nav:
            tocItem = #"    <item href="nav.xhtml" id="nav" media-type="application/xhtml+xml" properties="nav"/>"# + "\n"
        }
        let spineTOC = toc == .ncx ? #" toc="ncx""# : ""

        // `c2` reverses the attribute order: item attributes are unordered,
        // and href-before-id used to drop chapters.
        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(Self.container.utf8)),
            ("OEBPS/content.opf", Data("""
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Sample Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:language>en</dc:language>
                <dc:identifier id="uid">urn:margins:test</dc:identifier>
            \(coverMeta)  </metadata>
              <manifest>
                <item href="chapter1.xhtml" id="c1" media-type="application/xhtml+xml"/>
                <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
            \(coverItem)\(tocItem)  </manifest>
              <spine\(spineTOC)>
                <itemref idref="c1"/>
                <itemref idref="c2"/>
              </spine>
            </package>
            """.utf8)),
            ("OEBPS/chapter1.xhtml", Data(chapterDocument(title: "Introduction", body: "Hello chapter one.").utf8)),
            ("OEBPS/chapter2.xhtml", Data(chapterDocument(title: "The Market", body: "Hello chapter two.").utf8)),
        ]

        switch toc {
        case .none: break
        case .ncx: files.append(("OEBPS/toc.ncx", Data(Self.ncx.utf8)))
        case .nav: files.append(("OEBPS/nav.xhtml", Data(Self.navDocument.utf8)))
        }
        if cover != .none {
            files.append(("OEBPS/cover.png", sampleCoverPNG))
        }

        return try write(files, to: directory.appendingPathComponent(filename))
    }

    /// An EPUB whose chapters carry exactly the given `<title>` and
    /// first-heading text (either may be empty to omit the tag) and no TOC,
    /// for exercising the title fallback chain.
    static func epub(
        in directory: URL,
        named filename: String,
        bookTitle: String,
        chapters: [(documentTitle: String, heading: String)]
    ) throws -> String {
        let manifest = chapters.indices.map {
            "    <item href=\"ch\($0).xhtml\" id=\"c\($0)\" media-type=\"application/xhtml+xml\"/>\n"
        }.joined()
        let spine = chapters.indices.map { "    <itemref idref=\"c\($0)\"/>\n" }.joined()

        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(Self.container.utf8)),
            ("OEBPS/content.opf", Data("""
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(bookTitle)</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:language>en</dc:language>
                <dc:identifier id="uid">urn:margins:test</dc:identifier>
              </metadata>
              <manifest>
            \(manifest)  </manifest>
              <spine>
            \(spine)  </spine>
            </package>
            """.utf8)),
        ]

        for (index, chapter) in chapters.enumerated() {
            let titleTag = chapter.documentTitle.isEmpty
                ? "" : "<title>\(chapter.documentTitle)</title>"
            let headingTag = chapter.heading.isEmpty ? "" : "<h2>\(chapter.heading)</h2>"
            files.append(("OEBPS/ch\(index).xhtml", Data("""
            <?xml version="1.0"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>\(titleTag)</head>
            <body>\(headingTag)<p>Body text.</p></body>
            </html>
            """.utf8)))
        }

        return try write(files, to: directory.appendingPathComponent(filename))
    }

    // MARK: Structured builder

    /// One spine item for `epub(in:named:chapters:toc:guide:landmarks:)`.
    struct ChapterSpec {
        var filename: String
        /// `<title>` text; empty omits the tag.
        var documentTitle: String = ""
        /// `<h1>` text; empty omits the heading.
        var heading: String = ""
        var body: String = "Body text."
        /// `epub:type` on the document's `<body>`.
        var epubType: String? = nil
        var linear: Bool = true
        /// Raw markup instead of the heading/body pair (an `<img>` wrapper,
        /// say).
        var markedUpBody: String? = nil
        /// `nil` omits `media-type`, exercising the extension fallback.
        var mediaType: String? = "application/xhtml+xml"
        var properties: String? = nil
    }

    /// A nested table-of-contents entry: `href` may carry `#fragment`.
    struct TOCOutline {
        var label: String
        var href: String
        var children: [TOCOutline] = []

        init(_ label: String, _ href: String, children: [TOCOutline] = []) {
            self.label = label
            self.href = href
            self.children = children
        }
    }

    enum TOCStyle {
        case none
        case ncx([TOCOutline])
        case nav([TOCOutline])
    }

    /// Builds a book whose spine items and TOC the caller describes exactly:
    /// per-file `<title>`, heading, body, `epub:type`, and `linear`; a
    /// nested NCX or nav TOC; an optional guide; optional landmarks.
    static func epub(
        in directory: URL,
        named filename: String,
        bookTitle: String = "Sample Book",
        author: String = "Test Author",
        chapters: [ChapterSpec],
        toc: TOCStyle = .none,
        guide: [(type: String, href: String)] = [],
        landmarks: [(type: String, href: String)] = []
    ) throws -> String {
        var manifest: [String] = []
        for (index, chapter) in chapters.enumerated() {
            var item = #"    <item href="\#(escape(chapter.filename))" id="c\#(index)""#
            if let mediaType = chapter.mediaType {
                item += #" media-type="\#(escape(mediaType))""#
            }
            if let properties = chapter.properties {
                item += #" properties="\#(escape(properties))""#
            }
            item += "/>"
            manifest.append(item)
        }
        let spineAttr: String
        switch toc {
        case .none: spineAttr = ""
        case .ncx:
            manifest.append(#"    <item href="toc.ncx" id="ncx" media-type="application/x-dtbncx+xml"/>"#)
            spineAttr = #" toc="ncx""#
        case .nav:
            manifest.append(
                #"    <item href="nav.xhtml" id="nav" media-type="application/xhtml+xml" properties="nav"/>"#
            )
            spineAttr = ""
        }
        let spine = chapters.enumerated().map { index, chapter in
            #"    <itemref idref="c\#(index)"\#(chapter.linear ? "" : #" linear="no""#)/>"#
        }.joined(separator: "\n")
        let guideXML = guide.isEmpty ? "" : """
          <guide>
        \(guide.map { #"    <reference type="\#(escape($0.type))" href="\#(escape($0.href))"/>"# }.joined(separator: "\n"))
          </guide>

        """

        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(Self.container.utf8)),
            ("OEBPS/content.opf", Data("""
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(escape(bookTitle))</dc:title>
                <dc:creator>\(escape(author))</dc:creator>
                <dc:language>en</dc:language>
                <dc:identifier id="uid">urn:margins:test</dc:identifier>
              </metadata>
              <manifest>
            \(manifest.joined(separator: "\n"))
              </manifest>
            \(guideXML)  <spine\(spineAttr)>
            \(spine)
              </spine>
            </package>
            """.utf8)),
        ]

        for chapter in chapters {
            let titleTag = chapter.documentTitle.isEmpty
                ? "" : "<title>\(escape(chapter.documentTitle))</title>"
            let headingTag = chapter.heading.isEmpty ? "" : "<h1>\(escape(chapter.heading))</h1>"
            let body = chapter.markedUpBody
                ?? "\(headingTag)<p>\(escape(chapter.body))</p>"
            let type = chapter.epubType.map { #" epub:type="\#(escape($0))""# } ?? ""
            files.append(("OEBPS/\(chapter.filename)", Data("""
            <?xml version="1.0"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head>\(titleTag)</head>
            <body\(type)>\(body)</body>
            </html>
            """.utf8)))
        }

        switch toc {
        case .none:
            break
        case .ncx(let outlines):
            files.append(("OEBPS/toc.ncx", Data(Self.ncxXML(outlines).utf8)))
        case .nav(let outlines):
            files.append(("OEBPS/nav.xhtml", Data(Self.navXML(toc: outlines, landmarks: landmarks).utf8)))
        }

        return try write(files, to: directory.appendingPathComponent(filename))
    }

    private static func ncxXML(_ outlines: [TOCOutline]) -> String {
        var order = 0
        func points(_ nodes: [TOCOutline], indent: String) -> String {
            nodes.map { node in
                order += 1
                let id = order
                let children = points(node.children, indent: indent + "  ")
                var xml = "\(indent)<navPoint id=\"np-\(id)\" playOrder=\"\(id)\">\n"
                xml += "\(indent)  <navLabel><text>\(escape(node.label))</text></navLabel>\n"
                xml += "\(indent)  <content src=\"\(escape(node.href))\"/>\n"
                if !children.isEmpty { xml += children + "\n" }
                xml += "\(indent)</navPoint>"
                return xml
            }.joined(separator: "\n")
        }
        return """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
        \(points(outlines, indent: "    "))
          </navMap>
        </ncx>
        """
    }

    private static func navXML(
        toc: [TOCOutline], landmarks: [(type: String, href: String)]
    ) -> String {
        var body = ""
        if !landmarks.isEmpty {
            let items = landmarks.map {
                #"      <li><a epub:type="\#(escape($0.type))" href="\#(escape($0.href))">\#(escape($0.type.capitalized))</a></li>"#
            }.joined(separator: "\n")
            body += "  <nav epub:type=\"landmarks\">\n    <ol>\n\(items)\n    </ol>\n  </nav>\n"
        }
        if !toc.isEmpty {
            body += "  <nav epub:type=\"toc\" role=\"doc-toc\">\n    <ol>\n\(navList(toc))\n    </ol>\n  </nav>\n"
        }
        return """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body>
        \(body)</body>
        </html>
        """
    }

    private static func navList(_ nodes: [TOCOutline]) -> String {
        nodes.map { node in
            var xml = #"<li><a href="\#(escape(node.href))">\#(escape(node.label))</a>"#
            if !node.children.isEmpty {
                xml += "\n<ol>\(navList(node.children))</ol>\n"
            }
            xml += "</li>"
            return xml
        }.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Building

    private static func write(_ files: [(String, Data)], to url: URL) throws -> String {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: path == "mimetype" ? .none : .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url.path
    }

    private static func chapterDocument(title: String, body: String) -> String {
        """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(title)</title></head>
        <body><p>\(body)</p></body>
        </html>
        """
    }

    private static let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// `np-2` reverses the attribute order and the last entry points at a
    /// file that is not in the spine: both are ignored cleanly.
    private static let ncx = """
    <?xml version="1.0"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <navMap>
        <navPoint id="np-1" playOrder="1">
          <navLabel><text>Opening Remarks</text></navLabel>
          <content src="chapter1.xhtml#start"/>
          <navPoint playOrder="2" id="np-2">
            <navLabel><text>A Nested Aside</text></navLabel>
            <content src="chapter1.xhtml#aside"/>
          </navPoint>
        </navPoint>
        <navPoint id="np-3" playOrder="3">
          <navLabel><text>Market Day</text></navLabel>
          <content src="chapter2.xhtml"/>
        </navPoint>
        <navPoint id="np-4" playOrder="4">
          <navLabel><text>Colophon</text></navLabel>
          <content src="colophon.xhtml#end"/>
        </navPoint>
      </navMap>
    </ncx>
    """

    /// The `landmarks` nav comes first on purpose: only the one marked `toc`
    /// may drive the titles.
    private static let navDocument = """
    <?xml version="1.0"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>Contents</title></head>
    <body>
      <nav epub:type="landmarks">
        <ol><li><a href="chapter1.xhtml">Start Reading</a></li></ol>
      </nav>
      <nav epub:type="toc" role="doc-toc">
        <ol>
          <li><a href="chapter1.xhtml#start">Opening <em>Remarks</em></a>
            <ol><li><a href="chapter1.xhtml#aside">A Nested Aside</a></li></ol>
          </li>
          <li><a href="chapter2.xhtml">Market Day</a></li>
          <li><a href="colophon.xhtml#end">Colophon</a></li>
        </ol>
      </nav>
    </body>
    </html>
    """
}
