import Foundation
import ZIPFoundation

// Reads an EPUB's metadata, spine, table of contents, and cover.
//
// Two parsing styles, following the Rust original. The OPF metadata, the
// NCX, and the EPUB3 nav document are real XML and go through `XMLParser`.
// Everything else — the container's OPF pointer, the spine's `itemref`
// order, the EPUB2 cover pointer, and the `<title>`/`<h1>` probes inside
// chapter documents — is scanned out of the raw text, because chapter XHTML
// in the wild is frequently not well-formed and a strict parse would fail
// the import over markup nobody reads.

/// Everything an import needs from an EPUB file.
public struct EpubInfo: Sendable {
    public var title: String
    public var author: String
    public var language: String?
    public var chapters: [ChapterMeta]
    public var cover: CoverImage?
}

/// A cover image extracted from the EPUB: raw bytes plus the file extension
/// to store it under.
public struct CoverImage: Sendable, Equatable {
    public var bytes: Data
    public var fileExtension: String
}

public enum EpubParser {
    /// A title used verbatim by this many chapters is a book-wide template
    /// (Gutenberg's Ebookmaker stamps one `<title>` into every file), not a
    /// chapter name.
    static let sharedTitleLimit = 3

    public static func parse(path: String) throws -> EpubInfo {
        let archive = try openArchive(path)

        let container = try readText(archive, "META-INF/container.xml")
        guard let opfPath = findOPFPath(container) else {
            throw CoreError.epub("invalid epub: OPF path not found in container.xml")
        }
        let opf = try readText(archive, opfPath)
        let opfDir = parentDirectory(opfPath)

        let metadata = try parseMetadata(opf)
        let items = parseManifestItems(opf)
        let manifest = Dictionary(items.map { ($0.id, $0.href) }, uniquingKeysWith: { first, _ in first })
        let spine = parseSpine(opf)
        let cover = extractCover(archive, opf: opf, opfDir: opfDir)
        let toc = indexByPath(parseTOC(archive, opf: opf, opfDir: opfDir))

        // Titles resolve in two passes: collect every candidate first, then
        // pick, because the `<title>` rung needs to know which titles the
        // whole book shares before it can tell a chapter name from
        // boilerplate.
        var candidates: [ChapterCandidate] = []
        for (index, idref) in spine.enumerated() {
            guard let href = manifest[idref], isProbablyContent(href) else { continue }
            let fullHref = joinHref(opfDir, href)
            let document = try? readText(archive, fullHref)
            let entry = toc[normalizePath(fullHref)]
            candidates.append(
                ChapterCandidate(
                    index: index,
                    href: fullHref,
                    fragment: entry?.fragment,
                    tocTitle: entry?.title,
                    heading: document.flatMap(headingFromDocument),
                    documentTitle: document.flatMap(titleFromDocument)
                )
            )
        }

        let chapters = resolveChapterTitles(candidates, bookTitle: metadata.title)
        guard !chapters.isEmpty else {
            throw CoreError.epub("invalid epub: no readable chapters found")
        }

        return EpubInfo(
            title: metadata.title,
            author: metadata.author,
            language: metadata.language,
            chapters: chapters,
            cover: cover
        )
    }

    /// Extracts a cover image without parsing the full spine. Used by the
    /// library backfill for books imported before covers were extracted.
    /// Returns `nil` when the book has no (readable) cover.
    public static func extractCover(path: String) -> CoverImage? {
        guard let archive = try? openArchive(path),
              let container = try? readText(archive, "META-INF/container.xml"),
              let opfPath = findOPFPath(container),
              let opf = try? readText(archive, opfPath)
        else { return nil }
        return extractCover(archive, opf: opf, opfDir: parentDirectory(opfPath))
    }

    /// The bytes of one file inside the EPUB.
    public static func readEntry(path: String, entry: String) throws -> Data {
        try readData(try openArchive(path), entry)
    }

    // MARK: Archive access

    private static func openArchive(_ path: String) throws -> Archive {
        do {
            return try Archive(url: URL(fileURLWithPath: path), accessMode: .read)
        } catch {
            throw CoreError.epub("zip error: \(error.localizedDescription)")
        }
    }

    private static func readData(_ archive: Archive, _ path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw CoreError.epub("zip error: entry not found: \(path)")
        }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            throw CoreError.epub("zip error: \(error.localizedDescription)")
        }
        return data
    }

    private static func readText(_ archive: Archive, _ path: String) throws -> String {
        let data = try readData(archive, path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CoreError.epub("invalid epub: \(path) is not valid UTF-8")
        }
        return text
    }

    // MARK: Metadata

    struct Metadata {
        var title = "Untitled"
        var author = "Unknown"
        var language: String?
    }

    static func parseMetadata(_ opf: String) throws -> Metadata {
        let delegate = MetadataDelegate()
        guard runParser(opf, delegate) else {
            throw CoreError.epub("xml error: could not parse the package document")
        }
        return delegate.metadata
    }

    /// Reads `<dc:title>`, `<dc:creator>`, and `<dc:language>` from inside
    /// `<metadata>`. Matching is on the qualified name, as the Rust reader
    /// did, so an unprefixed `<title>` in the same block also counts.
    private final class MetadataDelegate: NSObject, XMLParserDelegate {
        var metadata = Metadata()
        private var inMetadata = false
        private var currentTag = ""
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            if name == "metadata" { inMetadata = true }
            guard inMetadata else { return }
            currentTag = name
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inMetadata, !currentTag.isEmpty else { return }
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            defer {
                if name == "metadata" { inMetadata = false }
                currentTag = ""
                text = ""
            }
            guard inMetadata, name == currentTag else { return }
            let value = String(text.trimmed)
            guard !value.isEmpty else { return }
            switch name {
            case "dc:title", "title": metadata.title = value
            case "dc:creator", "creator": metadata.author = value
            case "dc:language", "language": metadata.language = value
            default: break
            }
        }
    }

    // MARK: Manifest and spine

    struct ManifestItem {
        var id: String
        var href: String
        var mediaType: String?
        var properties: String?
    }

    static func parseManifestItems(_ opf: String) -> [ManifestItem] {
        let delegate = ManifestDelegate()
        guard runParser(opf, delegate) else { return [] }
        return delegate.items
    }

    private final class ManifestDelegate: NSObject, XMLParserDelegate {
        var items: [ManifestItem] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            guard localName(name) == "item" else { return }
            let attributes = attributes.reduce(into: [String: String]()) { result, pair in
                result[localName(pair.key)] = pair.value
            }
            guard let id = attributes["id"], let href = attributes["href"] else { return }
            items.append(
                ManifestItem(
                    id: id, href: href,
                    mediaType: attributes["media-type"], properties: attributes["properties"]
                )
            )
        }
    }

    /// Spine order, scanned rather than parsed: `<spine>` is a flat list of
    /// `itemref`s and this survives a package document that does not parse.
    static func parseSpine(_ opf: String) -> [String] {
        var result: [String] = []
        var cursor = opf.startIndex
        while let open = opf.range(of: "<itemref", range: cursor..<opf.endIndex) {
            guard let close = opf.range(of: ">", range: open.upperBound..<opf.endIndex) else { break }
            let tag = opf[open.upperBound..<close.lowerBound]
            if let idref = attributeValue("idref", in: tag), !idref.isEmpty {
                result.append(idref)
            }
            cursor = close.upperBound
        }
        return result
    }

    /// The OPF's path, from `<rootfile full-path="…">`.
    static func findOPFPath(_ containerXML: String) -> String? {
        attributeValue("full-path", in: Substring(containerXML)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// EPUB2 cover pointer: `<meta name="cover" content="manifest-id"/>`.
    /// The attributes may appear in either order.
    static func coverMetaID(_ opf: String) -> String? {
        var cursor = opf.startIndex
        while let open = opf.range(of: "<meta", range: cursor..<opf.endIndex) {
            guard let close = opf.range(of: ">", range: open.upperBound..<opf.endIndex) else { break }
            let tag = opf[open.upperBound..<close.lowerBound]
            if attributeValue("name", in: tag) == "cover",
               let content = attributeValue("content", in: tag), !content.isEmpty {
                return content
            }
            cursor = close.upperBound
        }
        return nil
    }

    static func spineTOCID(_ opf: String) -> String? {
        guard let open = opf.range(of: "<spine"),
              let close = opf.range(of: ">", range: open.upperBound..<opf.endIndex)
        else { return nil }
        return attributeValue("toc", in: opf[open.upperBound..<close.lowerBound])
    }

    /// The value of a double-quoted attribute inside a tag's body.
    private static func attributeValue(_ name: String, in tag: Substring) -> String? {
        var cursor = tag.startIndex
        while let equals = tag.range(of: "\(name)=\"", range: cursor..<tag.endIndex) {
            // Must be a whole attribute name, not the tail of another one.
            let before = equals.lowerBound
            let boundary = before == tag.startIndex
                || tag[tag.index(before: before)].isWhitespace
            guard boundary,
                  let end = tag.range(of: "\"", range: equals.upperBound..<tag.endIndex)
            else {
                cursor = equals.upperBound
                continue
            }
            return decodeEntities(String(tag[equals.upperBound..<end.lowerBound]))
        }
        return nil
    }

    // MARK: Cover

    /// Cover resolution order: EPUB3 `properties="cover-image"`, EPUB2
    /// `<meta name="cover" content="id">`, then the first manifest item with
    /// an image media type. Absent or unreadable covers yield `nil` —
    /// extraction must never fail an import.
    private static func extractCover(
        _ archive: Archive, opf: String, opfDir: String
    ) -> CoverImage? {
        let items = parseManifestItems(opf)
        var candidates: [ManifestItem] = []

        if let item = items.first(where: {
            $0.properties?.split(whereSeparator: \.isWhitespace).contains("cover-image") == true
        }) {
            candidates.append(item)
        }
        if let id = coverMetaID(opf), let item = items.first(where: { $0.id == id }) {
            candidates.append(item)
        }
        if let item = items.first(where: { $0.mediaType?.hasPrefix("image/") == true }) {
            candidates.append(item)
        }

        for item in candidates {
            guard let mediaType = item.mediaType,
                  let fileExtension = self.fileExtension(forMediaType: mediaType),
                  let bytes = try? readData(archive, joinHref(opfDir, item.href)),
                  !bytes.isEmpty
            else { continue }
            return CoverImage(bytes: bytes, fileExtension: fileExtension)
        }
        return nil
    }

    static func fileExtension(forMediaType mediaType: String) -> String? {
        switch mediaType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/svg+xml": return "svg"
        case "image/webp": return "webp"
        default: return nil
        }
    }

    // MARK: Table of contents

    /// One TOC entry, flattened out of the nav document or NCX in reading
    /// order and resolved against the book root.
    struct TOCEntry: Equatable {
        var title: String
        /// In-zip path of the target file, normalized for comparison.
        var path: String
        var fragment: String?
    }

    /// The book's table of contents, preferring the EPUB3 nav document and
    /// falling back to the NCX. TOC parsing is best-effort by design: a
    /// malformed or missing TOC yields an empty list rather than failing the
    /// import, and the title chain simply falls through to the next rung.
    static func parseTOC(_ archive: Archive, opf: String, opfDir: String) -> [TOCEntry] {
        let items = parseManifestItems(opf)

        if let nav = items.first(where: {
            $0.properties?.split(whereSeparator: \.isWhitespace).contains("nav") == true
        }) {
            let path = joinHref(opfDir, nav.href)
            if let document = try? readText(archive, path) {
                let entries = parseNavDocument(document, baseDir: parentDirectory(path))
                if !entries.isEmpty { return entries }
            }
        }

        // NCX: the declared media type first, then the id named by
        // `<spine toc="…">`, then any `.ncx` in the manifest.
        let ncx = items.first { $0.mediaType == "application/x-dtbncx+xml" }
            ?? spineTOCID(opf).flatMap { id in items.first { $0.id == id } }
            ?? items.first { $0.href.lowercased().hasSuffix(".ncx") }
        if let ncx {
            let path = joinHref(opfDir, ncx.href)
            if let document = try? readText(archive, path) {
                return parseNCX(document, baseDir: parentDirectory(path))
            }
        }
        return []
    }

    /// Indexes the TOC by target path, first entry in reading order winning:
    /// a file split into several TOC entries starts at the first of them.
    static func indexByPath(_ entries: [TOCEntry]) -> [String: TOCEntry] {
        Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// EPUB3 nav document: the `<nav>` marked as the TOC (`epub:type="toc"`,
    /// else `role="doc-toc"`, else the first one with links), flattened to
    /// its anchors in document order.
    static func parseNavDocument(_ xml: String, baseDir: String) -> [TOCEntry] {
        let delegate = NavDelegate()
        guard runParser(xml, delegate) else { return [] }

        let chosen = delegate.sections.first {
            $0.epubType?.split(whereSeparator: \.isWhitespace).contains("toc") == true
        } ?? delegate.sections.first { $0.role == "doc-toc" }
            ?? delegate.sections.first { !$0.anchors.isEmpty }

        guard let chosen else { return [] }
        return chosen.anchors.compactMap { tocEntry(baseDir: baseDir, src: $0.href, label: $0.label) }
    }

    private final class NavDelegate: NSObject, XMLParserDelegate {
        struct Section {
            var epubType: String?
            var role: String?
            var anchors: [(href: String, label: String)] = []
        }

        var sections: [Section] = []
        /// Indices of the `<nav>` elements currently open; anchors belong to
        /// the innermost one.
        private var open: [Int] = []
        private var anchor: (href: String, label: String)?

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            let attributes = attributes.reduce(into: [String: String]()) { result, pair in
                result[localName(pair.key)] = pair.value
            }
            switch localName(name) {
            case "nav":
                open.append(sections.count)
                sections.append(
                    Section(epubType: attributes["type"], role: attributes["role"])
                )
            case "a" where !open.isEmpty:
                anchor = attributes["href"].map { ($0, "") }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            anchor?.label += string
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch localName(name) {
            case "nav":
                _ = open.popLast()
                anchor = nil
            case "a":
                if let anchor, let index = open.last {
                    sections[index].anchors.append(anchor)
                }
                anchor = nil
            default:
                break
            }
        }
    }

    /// NCX `navMap`: nested `navPoint`s flattened depth-first. Each point is
    /// emitted at the slot it opened, so a parent still precedes its
    /// children even though its `</navPoint>` closes last.
    static func parseNCX(_ xml: String, baseDir: String) -> [TOCEntry] {
        let delegate = NCXDelegate(baseDir: baseDir)
        guard runParser(xml, delegate) else { return [] }
        return delegate.entries
    }

    private final class NCXDelegate: NSObject, XMLParserDelegate {
        /// A navPoint being read: `slot` is where it goes in reading order,
        /// held open until `</navPoint>` so a parent still precedes the
        /// children that close before it.
        private struct Pending {
            var slot: Int
            var label = ""
            var src: String?
        }

        var entries: [TOCEntry] = []
        private var stack: [Pending] = []
        private var inLabel = false
        private var inText = false
        private let baseDir: String

        init(baseDir: String) {
            self.baseDir = baseDir
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            switch localName(name) {
            case "navPoint":
                stack.append(Pending(slot: entries.count))
            case "navLabel":
                inLabel = true
            case "text" where inLabel:
                inText = true
            case "content":
                // The first `src` wins: a malformed point with two targets
                // starts where it says first.
                let src = attributes.first { localName($0.key) == "src" }?.value
                if let src, !stack.isEmpty, stack[stack.count - 1].src == nil {
                    stack[stack.count - 1].src = src
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inText, !stack.isEmpty else { return }
            stack[stack.count - 1].label += string
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch localName(name) {
            case "navPoint":
                guard let pending = stack.popLast() else { return }
                if let src = pending.src,
                   let entry = EpubParser.tocEntry(baseDir: baseDir, src: src, label: pending.label) {
                    entries.insert(entry, at: pending.slot)
                }
            case "navLabel":
                inLabel = false
            case "text":
                inText = false
            default:
                break
            }
        }
    }

    /// Builds an entry from a raw TOC target and label, dropping ones with
    /// no usable label or path.
    static func tocEntry(baseDir: String, src: String, label: String) -> TOCEntry? {
        guard let title = cleanText(label) else { return nil }
        let parts = src.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = normalizePath(resolveRelative(baseDir, percentDecode(String(parts[0]))))
        guard !path.isEmpty else { return nil }
        let fragment = parts.count > 1 ? percentDecode(String(parts[1])) : nil
        return TOCEntry(
            title: title, path: path, fragment: fragment.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Titles

    /// Every title source found for one spine item, before the chain picks
    /// between them.
    struct ChapterCandidate {
        var index: Int
        var href: String
        var fragment: String?
        var tocTitle: String?
        var heading: String?
        var documentTitle: String?
    }

    /// Applies the title chain — TOC label, first heading, `<title>`, then a
    /// positional fallback — with the shared-title pass that disqualifies
    /// boilerplate. TOC labels are trusted as-is; they are per-entry by
    /// construction.
    static func resolveChapterTitles(
        _ candidates: [ChapterCandidate], bookTitle: String
    ) -> [ChapterMeta] {
        let sharedHeadings = sharedValues(candidates.compactMap(\.heading))
        let sharedTitles = sharedValues(candidates.compactMap(\.documentTitle))

        return candidates.map { candidate in
            let heading = candidate.heading.flatMap { sharedHeadings.contains($0) ? nil : $0 }
            let documentTitle = candidate.documentTitle.flatMap {
                sharedTitles.contains($0) || isBoilerplateTitle($0, bookTitle: bookTitle) ? nil : $0
            }
            let title = candidate.tocTitle ?? heading ?? documentTitle
                ?? "Chapter \(candidate.index + 1)"
            return ChapterMeta(
                key: String(format: "%03d", candidate.index + 1),
                index: candidate.index,
                title: title,
                href: candidate.href,
                fragment: candidate.fragment
            )
        }
    }

    private static func sharedValues(_ values: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return Set(counts.filter { $0.value >= sharedTitleLimit }.keys)
    }

    /// The book's own name and Gutenberg's wrapper line are never a chapter
    /// title, even in a book short enough to dodge the shared-title count.
    static func isBoilerplateTitle(_ title: String, bookTitle: String) -> Bool {
        let title = String(title.trimmed)
        return title.compare(String(bookTitle.trimmed), options: .caseInsensitive) == .orderedSame
            || title.lowercased().hasPrefix("the project gutenberg ebook")
    }

    static func titleFromDocument(_ document: String) -> String? {
        firstElementBody(in: document, names: ["title"]).flatMap { cleanText(String($0)) }
    }

    /// The chapter's own first `<h1>`–`<h3>`: where the real name lives in
    /// books whose `<title>` is a template. Absurdly long matches are
    /// rejected — that is a heading wrapping the whole page, not a name.
    static func headingFromDocument(_ document: String) -> String? {
        firstElementBody(in: document, names: ["h1", "h2", "h3"])
            .flatMap { cleanText(String($0)) }
            .flatMap { $0.count <= 200 ? $0 : nil }
    }

    /// The text between the earliest opening tag among `names` and the next
    /// closing tag among them — the leftmost-shortest match the Rust
    /// regexes made.
    private static func firstElementBody(in document: String, names: [String]) -> Substring? {
        var best: Range<String.Index>?
        for name in names {
            guard let open = range(ofTagNamed: name, closing: false, in: document, from: document.startIndex)
            else { continue }
            if best == nil || open.lowerBound < best!.lowerBound { best = open }
        }
        guard let open = best else { return nil }

        var close: Range<String.Index>?
        for name in names {
            guard let found = range(ofTagNamed: name, closing: true, in: document, from: open.upperBound)
            else { continue }
            if close == nil || found.lowerBound < close!.lowerBound { close = found }
        }
        guard let close else { return nil }
        return document[open.upperBound..<close.lowerBound]
    }

    /// The full `<name…>` or `</name…>` tag at or after `start`.
    private static func range(
        ofTagNamed name: String, closing: Bool, in document: String, from start: String.Index
    ) -> Range<String.Index>? {
        let opener = closing ? "</" : "<"
        guard let hit = document.range(
            of: opener + name, options: .caseInsensitive, range: start..<document.endIndex
        ), let close = document.range(of: ">", range: hit.upperBound..<document.endIndex)
        else { return nil }
        return hit.lowerBound..<close.upperBound
    }

    /// Flattens a snippet of markup to display text: tags out, entities
    /// decoded, whitespace collapsed. `nil` when nothing is left.
    static func cleanText(_ markup: String) -> String? {
        var stripped = ""
        var cursor = markup.startIndex
        while let open = markup.range(of: "<", range: cursor..<markup.endIndex) {
            stripped += markup[cursor..<open.lowerBound]
            guard let close = markup.range(of: ">", range: open.upperBound..<markup.endIndex) else {
                // An unterminated tag is text, as the Rust regex left it.
                cursor = open.lowerBound
                break
            }
            stripped += " "
            cursor = close.upperBound
        }
        stripped += markup[cursor...]

        let collapsed = decodeEntities(stripped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Decodes the handful of entities that show up in titles and headings,
    /// plus numeric references. Unknown entities are left alone.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var cursor = text.startIndex

        while let start = text.range(of: "&", range: cursor..<text.endIndex) {
            out += text[cursor..<start.lowerBound]
            // Entity names are short; a `&` with no `;` close by is literal.
            let limit = text.index(start.lowerBound, offsetBy: 12, limitedBy: text.endIndex)
                ?? text.endIndex
            guard let end = text.range(of: ";", range: start.upperBound..<limit),
                  let decoded = decodeEntity(String(text[start.upperBound..<end.lowerBound]))
            else {
                out += "&"
                cursor = start.upperBound
                continue
            }
            out.append(decoded)
            cursor = end.upperBound
        }
        out += text[cursor...]
        return out
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "hellip": return "\u{2026}"
        case "rsquo": return "\u{2019}"
        case "lsquo": return "\u{2018}"
        case "ldquo": return "\u{201C}"
        case "rdquo": return "\u{201D}"
        default: return numericEntity(entity)
        }
    }

    private static func numericEntity(_ entity: String) -> Character? {
        guard let digits = entity.strippingPrefix("#") else { return nil }
        let code: UInt32?
        if let hex = digits.strippingPrefix("x") ?? digits.strippingPrefix("X") {
            code = UInt32(hex, radix: 16)
        } else {
            code = UInt32(digits)
        }
        return code.flatMap(Unicode.Scalar.init).map(Character.init)
    }

    // MARK: Paths

    static func isProbablyContent(_ href: String) -> Bool {
        let lower = href.lowercased()
        return !(lower.hasSuffix(".ncx")
            || lower.contains("toc")
            || lower.contains("nav")
            || lower.hasSuffix(".css")
            || lower.hasSuffix(".jpg")
            || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".png")
            || lower.hasSuffix(".gif")
            || lower.hasSuffix(".svg"))
    }

    static func joinHref(_ baseDir: String, _ href: String) -> String {
        guard !baseDir.isEmpty else { return href }
        var base = Substring(baseDir)
        while base.hasSuffix("/") { base = base.dropLast() }
        var relative = Substring(href)
        while relative.hasPrefix("/") { relative = relative.dropFirst() }
        return "\(base)/\(relative)"
    }

    static func parentDirectory(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Resolves a TOC target against the directory of the document that
    /// declared it (nav/NCX srcs are relative to that file, not the OPF),
    /// collapsing `.` and `..`.
    static func resolveRelative(_ baseDir: String, _ href: String) -> String {
        var stack: [Substring] = href.hasPrefix("/")
            ? []
            : baseDir.split(separator: "/", omittingEmptySubsequences: true)
        for part in href.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case "", ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(part)
            }
        }
        return stack.joined(separator: "/")
    }

    /// Comparison form of an in-zip path: percent-decoded, with any leading
    /// `./` or `/` removed, so a TOC target and a manifest href for the same
    /// file agree however each was written.
    static func normalizePath(_ path: String) -> String {
        resolveRelative("", percentDecode(path))
    }

    static func percentDecode(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self),
                                radix: 16) {
                out.append(byte)
                index += 3
                continue
            }
            out.append(bytes[index])
            index += 1
        }
        return String(bytes: out, encoding: .utf8) ?? text
    }

    // MARK: XML plumbing

    /// Runs a delegate over a document, reporting whether it parsed. The
    /// callers that can carry on without the document swallow `false`.
    private static func runParser(_ xml: String, _ delegate: some XMLParserDelegate) -> Bool {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        // Namespaces stay off so element names arrive qualified, the way the
        // Rust reader saw them; `localName` strips a prefix where the
        // original compared local names.
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }
}

/// The part of a qualified XML name after the prefix.
private func localName(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
}
