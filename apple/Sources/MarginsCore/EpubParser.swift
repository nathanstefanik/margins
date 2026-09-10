import Foundation
import ZIPFoundation

// Reads an EPUB's metadata, spine, table of contents, cover, and structure.
//
// Two parsing styles, following the Rust original. The OPF metadata and
// spine, the NCX, and the EPUB3 nav document are real XML and go through
// `XMLParser`. Everything else — the container's OPF pointer, the EPUB2
// cover pointer, `epub:type` probes, and the `<title>`/`<h1>` probes inside
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

    /// Per-document `epub:type` lives on `<body>` or the first `<section>`;
    /// only the head of the document is scanned for it.
    static let documentTypeScanLimit = 8 * 1024

    /// A file with almost no visible text and an image is a cover wrapper
    /// (Gutenberg's `wrap0000.html`), not a chapter.
    static let coverShapeTextLimit = 40

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
        let manifest = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spine = parseSpine(opf)
        let cover = extractCover(archive, opf: opf, opfDir: opfDir)
        let toc = indexByPath(parseTOC(archive, opf: opf, opfDir: opfDir))
        let bookSignals = mergeSignals(
            guide: parseGuide(opf, opfDir: opfDir),
            landmarks: parseLandmarks(archive, opf: opf, opfDir: opfDir)
        )

        // Titles resolve in two passes: collect every candidate first, then
        // pick, because the `<title>` rung needs to know which titles the
        // whole book shares before it can tell a chapter name from
        // boilerplate. Classification runs after titles too, because the
        // title heuristics read them.
        var candidates: [ChapterCandidate] = []
        for (index, item) in spine.enumerated() {
            guard item.linear, let manifestItem = manifest[item.idref],
                  isContentItem(manifestItem) else { continue }
            let fullHref = joinHref(opfDir, manifestItem.href)
            let document = try? readText(archive, fullHref)
            candidates.append(
                ChapterCandidate(
                    index: index,
                    href: fullHref,
                    tocEntries: toc[normalizePath(fullHref)] ?? [],
                    heading: document.flatMap(headingFromDocument),
                    documentTitle: document.flatMap(titleFromDocument),
                    explicitMatter: bookSignals[normalizePath(fullHref)]
                        ?? document.flatMap(documentEpubType).flatMap(documentTypeMatter)
                        ?? (document.map(isCoverByShape) == true ? .cover : nil)
                )
            )
        }

        let chapters = resolveChapters(candidates, bookTitle: metadata.title)
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

    /// One `<itemref>`: the manifest id and whether it is part of the
    /// linear reading order.
    struct SpineItem: Equatable {
        var idref: String
        var linear: Bool
    }

    /// Spine order via `XMLParser`, keeping `linear` so `linear="no"` items
    /// can be dropped without disturbing the raw positions keys come from.
    static func parseSpine(_ opf: String) -> [SpineItem] {
        let delegate = SpineDelegate()
        guard runParser(opf, delegate) else { return [] }
        return delegate.items
    }

    private final class SpineDelegate: NSObject, XMLParserDelegate {
        var items: [SpineItem] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            guard localName(name) == "itemref" else { return }
            let attributes = attributes.reduce(into: [String: String]()) { result, pair in
                result[localName(pair.key)] = pair.value
            }
            guard let idref = attributes["idref"], !idref.isEmpty else { return }
            items.append(SpineItem(idref: idref, linear: attributes["linear"]?.lowercased() != "no"))
        }
    }

    /// EPUB2 `<guide><reference type= href=>`: the book-level classification
    /// map for older books, resolved against the OPF's directory.
    static func parseGuide(_ opf: String, opfDir: String) -> [String: Matter] {
        let delegate = GuideDelegate()
        guard runParser(opf, delegate) else { return [:] }
        var signals: [String: Matter] = [:]
        for reference in delegate.references {
            guard let matter = guideMatter(reference.type) else { continue }
            signals[resolveTarget(baseDir: opfDir, href: reference.href)] = matter
        }
        return signals
    }

    private final class GuideDelegate: NSObject, XMLParserDelegate {
        var references: [(type: String, href: String)] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            guard localName(name) == "reference" else { return }
            let attributes = attributes.reduce(into: [String: String]()) { result, pair in
                result[localName(pair.key)] = pair.value
            }
            guard let type = attributes["type"], let href = attributes["href"] else { return }
            references.append((type, href))
        }
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
        /// Outline depth: 0 for a top-level entry, one deeper per nesting
        /// level. Inferred from the label when the whole TOC is flat.
        var level: Int
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
                if !entries.isEmpty { return withInferredLevels(entries) }
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
                return withInferredLevels(parseNCX(document, baseDir: parentDirectory(path)))
            }
        }
        return []
    }

    /// Indexes the TOC by target path, keeping every entry in reading order:
    /// a file split into several TOC entries carries them all.
    static func indexByPath(_ entries: [TOCEntry]) -> [String: [TOCEntry]] {
        var index: [String: [TOCEntry]] = [:]
        for entry in entries {
            index[entry.path, default: []].append(entry)
        }
        return index
    }

    /// Infers levels from labels for entries the TOC itself left at level 0:
    /// parts/volumes open a level 0 run, books are level 1 under them, and
    /// everything else is a leaf one below the deepest container seen so
    /// far. Entries at a deeper authored level keep it — a nested TOC is
    /// authoritative for what it nests — but they raise the container floor
    /// for later level-0 siblings. (Karamazov's NCX is flat for its 118 body
    /// entries except for one incidental nested front-matter point; a strict
    /// "only when every entry is level 0" test would leave its parts, books,
    /// and chapters undifferentiated.)
    static func withInferredLevels(_ entries: [TOCEntry]) -> [TOCEntry] {
        let hasParts = entries.contains {
            titleMatches($0.title, "part") || titleMatches($0.title, "volume")
        }
        var container = -1
        return entries.map { entry in
            guard entry.level == 0 else {
                container = max(container, entry.level)
                return entry
            }
            var entry = entry
            if titleMatches(entry.title, "part") || titleMatches(entry.title, "volume") {
                entry.level = 0
                container = 0
            } else if titleMatches(entry.title, "book") {
                entry.level = hasParts ? 1 : 0
                container = max(container, entry.level)
            } else {
                entry.level = container + 1
            }
            return entry
        }
    }

    /// EPUB3 nav document: the `<nav>` marked as the TOC (`epub:type="toc"`,
    /// else `role="doc-toc"`, else the first one with links), flattened to
    /// its anchors in document order, each at its `<ol>` depth inside the
    /// chosen nav.
    static func parseNavDocument(_ xml: String, baseDir: String) -> [TOCEntry] {
        let delegate = NavDelegate()
        guard runParser(xml, delegate) else { return [] }

        let chosen = delegate.sections.first {
            $0.epubType?.split(whereSeparator: \.isWhitespace).contains("toc") == true
        } ?? delegate.sections.first { $0.role == "doc-toc" }
            ?? delegate.sections.first { !$0.anchors.isEmpty }

        guard let chosen else { return [] }
        return chosen.anchors.compactMap {
            tocEntry(baseDir: baseDir, src: $0.href, label: $0.label, level: $0.level)
        }
    }

    /// The book-level classification map from the nav document's landmarks
    /// (`epub:type="landmarks"` anchors). Resolved like TOC targets.
    static func parseLandmarks(
        _ archive: Archive, opf: String, opfDir: String
    ) -> [String: Matter] {
        let items = parseManifestItems(opf)
        guard let nav = items.first(where: {
            $0.properties?.split(whereSeparator: \.isWhitespace).contains("nav") == true
        }) else { return [:] }
        let path = joinHref(opfDir, nav.href)
        guard let document = try? readText(archive, path) else { return [:] }

        let delegate = NavDelegate()
        guard runParser(document, delegate) else { return [:] }
        guard let landmarks = delegate.sections.first(where: {
            $0.epubType?.split(whereSeparator: \.isWhitespace).contains("landmarks") == true
        }) else { return [:] }

        var signals: [String: Matter] = [:]
        for anchor in landmarks.anchors {
            guard let type = anchor.type, let matter = landmarkMatter(type) else { continue }
            signals[resolveTarget(baseDir: parentDirectory(path), href: anchor.href)] = matter
        }
        return signals
    }

    /// Landmarks override the guide: EPUB3 metadata is more specific than
    /// the EPUB2 guide it replaced.
    static func mergeSignals(
        guide: [String: Matter], landmarks: [String: Matter]
    ) -> [String: Matter] {
        var merged = guide
        merged.merge(landmarks) { _, landmark in landmark }
        return merged
    }

    private final class NavDelegate: NSObject, XMLParserDelegate {
        struct Anchor {
            var href: String
            var label: String
            var type: String?
            var level: Int
        }

        struct Section {
            var epubType: String?
            var role: String?
            var anchors: [Anchor] = []
        }

        var sections: [Section] = []
        /// Indices of the `<nav>` elements currently open; anchors belong to
        /// the innermost one.
        private var open: [Int] = []
        /// `<ol>` elements open inside the innermost nav; an anchor's level
        /// is its `<ol>` nesting minus one.
        private var listDepth = 0
        private var anchor: (href: String, type: String?, label: String)?

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
                listDepth = 0
            case "ol" where !open.isEmpty:
                listDepth += 1
            case "a" where !open.isEmpty:
                anchor = (attributes["href"] ?? "", attributes["type"], "")
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
                listDepth = 0
                anchor = nil
            case "ol" where !open.isEmpty:
                listDepth = max(0, listDepth - 1)
            case "a":
                if let anchor, let index = open.last, !anchor.href.isEmpty {
                    sections[index].anchors.append(
                        Anchor(
                            href: anchor.href, label: anchor.label, type: anchor.type,
                            level: max(0, listDepth - 1)
                        )
                    )
                }
                self.anchor = nil
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
        /// `level` is its depth (0 at the top), held open until
        /// `</navPoint>` so a parent still precedes the children that close
        /// before it.
        private struct Pending {
            var slot: Int
            var level: Int
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
                stack.append(Pending(slot: entries.count, level: stack.count))
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
                   let entry = EpubParser.tocEntry(
                       baseDir: baseDir, src: src, label: pending.label, level: pending.level
                   ) {
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
    static func tocEntry(
        baseDir: String, src: String, label: String, level: Int = 0
    ) -> TOCEntry? {
        guard let title = cleanText(label) else { return nil }
        guard !src.isEmpty else { return nil }
        let parts = src.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = normalizePath(resolveRelative(baseDir, percentDecode(String(parts[0]))))
        guard !path.isEmpty else { return nil }
        let fragment = parts.count > 1 ? percentDecode(String(parts[1])) : nil
        return TOCEntry(
            title: title, path: path, fragment: fragment.flatMap { $0.isEmpty ? nil : $0 },
            level: level
        )
    }

    /// Resolves a book-level signal target (landmark or guide reference)
    /// against the declaring document, dropping any fragment and decoding
    /// percent escapes, so it matches the manifest path.
    static func resolveTarget(baseDir: String, href: String) -> String {
        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        return normalizePath(resolveRelative(baseDir, percentDecode(String(path[0]))))
    }

    // MARK: Titles and matter

    /// Every title and classification source found for one spine item,
    /// before the chain picks between the titles and the signals decide the
    /// matter.
    struct ChapterCandidate {
        var index: Int
        var href: String
        /// Every TOC entry for the file, in reading order.
        var tocEntries: [TOCEntry]
        var heading: String?
        var documentTitle: String?
        /// From landmarks, the guide, the document's `epub:type`, or its
        /// shape; `nil` when no signal names the file.
        var explicitMatter: Matter?
    }

    /// Applies the title chain and then classifies each file. TOC labels are
    /// trusted as-is; they are per-entry by construction.
    static func resolveChapters(
        _ candidates: [ChapterCandidate], bookTitle: String
    ) -> [ChapterMeta] {
        let titles = resolveTitles(candidates, bookTitle: bookTitle)
        let matters = classifyMatter(candidates, titles: titles, bookTitle: bookTitle)

        return candidates.enumerated().map { index, candidate in
            let sections = candidate.tocEntries.map {
                ChapterSection(title: $0.title, fragment: $0.fragment, level: $0.level)
            }
            return ChapterMeta(
                key: String(format: "%03d", candidate.index + 1),
                index: candidate.index,
                title: titles[index],
                href: candidate.href,
                fragment: sections.first?.fragment,
                matter: matters[index],
                level: sections.first?.level ?? 0,
                sections: sections
            )
        }
    }

    /// The title chain — TOC label, first heading, `<title>`, then a
    /// positional fallback — with the shared-title pass that disqualifies
    /// boilerplate.
    static func resolveTitles(
        _ candidates: [ChapterCandidate], bookTitle: String
    ) -> [String] {
        let sharedHeadings = sharedValues(candidates.compactMap(\.heading))
        let sharedTitles = sharedValues(candidates.compactMap(\.documentTitle))

        return candidates.map { candidate in
            let heading = candidate.heading.flatMap { sharedHeadings.contains($0) ? nil : $0 }
            let documentTitle = candidate.documentTitle.flatMap {
                sharedTitles.contains($0) || isBoilerplateTitle($0, bookTitle: bookTitle) ? nil : $0
            }
            return candidate.tocEntries.first?.title ?? heading ?? documentTitle
                ?? "Chapter \(candidate.index + 1)"
        }
    }

    // MARK: Matter classification

    /// The title heuristics' front-matter list. Matched case-insensitively
    /// as the whole trimmed title or as a prefix followed by a non-letter;
    /// "introduction" catches "Introduction" and "Introduction: …" but not
    /// "Introductionary".
    static let frontMatterTitles = [
        "half title", "halftitle", "half-title", "title page", "series page",
        "copyright", "acknowledgments", "acknowledgements", "dedication",
        "contents", "table of contents", "epigraph", "about the author",
        "also by", "by the same author", "a note on the", "note on the",
        "translator's note", "translators' note", "texts used",
        "select bibliography", "further reading", "chronology", "a chronology",
        "principal characters", "list of", "introduction", "preface",
        "foreword", "from the author", "author's note",
    ]

    /// The title heuristics' back-matter list.
    static let backMatterTitles = [
        "notes", "endnotes", "footnotes", "explanatory notes", "glossary",
        "index", "appendix", "afterword", "bibliography", "colophon",
        "about the publisher", "other books by", "also available",
    ]

    /// The classification pass: signals 1–3 decide first, then title
    /// heuristics inside the front and back runs, then position. A file the
    /// TOC labels as a part/book/volume/chapter (or begins with a number or
    /// Roman numeral) is Body regardless of its title. Keys and order are
    /// never affected.
    static func classifyMatter(
        _ candidates: [ChapterCandidate], titles: [String], bookTitle: String
    ) -> [Matter] {
        let count = candidates.count
        var matters = [Matter?](repeating: nil, count: count)
        var structural = [Bool](repeating: false, count: count)

        for index in 0..<count {
            matters[index] = candidates[index].explicitMatter
            let labels = candidates[index].tocEntries.map(\.title) + [titles[index]]
            structural[index] = labels.contains(where: isStructuralLabel)
        }

        // Where Body starts: an explicit signal, then a structural label,
        // then position — the first file that is neither Cover nor Front by
        // signals 2–4.
        var bodyStart: Int?
        if let first = matters.firstIndex(of: .body) {
            bodyStart = first
        } else if let first = structural.firstIndex(of: true) {
            bodyStart = first
        } else {
            var index = 0
            while index < count {
                if matters[index] == .cover || matters[index] == .front || matters[index] == .back {
                    index += 1
                    continue
                }
                if frontMatter(titles[index], bookTitle: bookTitle) != nil {
                    index += 1
                    continue
                }
                break
            }
            bodyStart = index < count ? index : nil
        }

        // The run before Body: title heuristics name front matter; leftovers
        // are front matter by position, unless a section label makes them
        // Body (a part before an explicit `bodymatter` landmark, say).
        if let bodyStart {
            for index in 0..<bodyStart where matters[index] == nil {
                if structural[index] {
                    matters[index] = .body
                } else {
                    matters[index] = frontMatter(titles[index], bookTitle: bookTitle) ?? .front
                }
            }
        }

        // A structural label is Body unless a book-level signal said
        // otherwise (landmarks/guide outrank the title sanity rule).
        for index in 0..<count where structural[index] && matters[index] == nil {
            matters[index] = .body
        }

        // The run after Body: back titles only, as a maximal suffix; the
        // files between the last body item and that suffix stay Body.
        let lastBody = matters.lastIndex(of: .body) ?? -1
        if lastBody + 1 < count {
            for index in stride(from: count - 1, through: lastBody + 1, by: -1) {
                if matters[index] == .back { continue }
                guard matters[index] == nil, !structural[index],
                      backMatter(titles[index]) != nil else { break }
                matters[index] = .back
            }
            for index in (lastBody + 1)..<count where matters[index] == nil {
                matters[index] = .body
            }
        }

        // Sanity: a book with no Body at all (an all-front-matter TOC) reads
        // from its first non-cover file.
        if !matters.contains(.body) {
            for index in 0..<count where matters[index] != .cover {
                matters[index] = .body
            }
        }

        return matters.map { $0 ?? .body }
    }

    /// Front-matter titles, plus "Cover" (its own matter), the book's own
    /// title, and an all-caps short title — a series name stamped on a
    /// front-matter page.
    static func frontMatter(_ title: String, bookTitle: String) -> Matter? {
        if titleMatches(title, "cover") { return .cover }
        if frontMatterTitles.contains(where: { titleMatches(title, $0) }) { return .front }
        let trimmed = title.trimmed
        if trimmed.compare(bookTitle.trimmed, options: .caseInsensitive) == .orderedSame {
            return .front
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if !words.isEmpty, words.count <= 4,
           trimmed.uppercased() == trimmed, trimmed.contains(where: \.isLetter) {
            return .front
        }
        return nil
    }

    /// Back-matter titles for the trailing run only.
    static func backMatter(_ title: String) -> Matter? {
        backMatterTitles.contains(where: { titleMatches(title, $0) }) ? .back : nil
    }

    /// The sanity escape hatch: a section labeled part/book/volume/chapter,
    /// or numbered (Arabic or Roman), is Body whatever its title says.
    static func isStructuralLabel(_ label: String) -> Bool {
        let trimmed = String(label.trimmed)
        for prefix in ["part", "book", "volume", "chapter"] where titleMatches(trimmed, prefix) {
            return true
        }
        if let first = trimmed.first, first.isNumber { return true }
        return startsWithRomanNumeral(trimmed)
    }

    /// Whole-string or prefix-until-non-letter, case-insensitive:
    /// "introduction" matches "Introduction: A Note" but not "Introductions".
    static func titleMatches(_ title: String, _ needle: String) -> Bool {
        let title = title.trimmed.lowercased()
        guard title.hasPrefix(needle) else { return false }
        guard title.count > needle.count else { return true }
        return !title[title.index(title.startIndex, offsetBy: needle.count)].isLetter
    }

    /// `^[IVXLCDM]+\b`, case-insensitive: "I. Fyodor", "IV", and "V." count;
    /// "In", "Very", and "Mitya" do not.
    static func startsWithRomanNumeral(_ label: String) -> Bool {
        let letters = CharacterSet(charactersIn: "IVXLCDM")
        let upper = label.trimmed.uppercased()
        var count = 0
        for scalar in upper.unicodeScalars {
            guard letters.contains(scalar) else { break }
            count += 1
        }
        guard count > 0 else { return false }
        let rest = upper.dropFirst(count)
        return rest.isEmpty || !rest.first!.isLetter
    }

    /// The classification value of one `epub:type` token list (from a
    /// `<body>`, a `<section>`, a landmark, or a guide reference).
    static func documentTypeMatter(_ raw: String) -> Matter? {
        let tokens = raw.lowercased().split(whereSeparator: \.isWhitespace)
        if tokens.contains("cover") { return .cover }
        if tokens.contains("bodymatter") { return .body }
        if tokens.contains("frontmatter") { return .front }
        if tokens.contains("backmatter") { return .back }
        for token in tokens {
            switch token {
            case "titlepage", "halftitlepage", "copyright-page", "toc", "dedication",
                 "acknowledgments", "acknowledgements", "epigraph", "foreword", "preface",
                 "introduction", "landmarks", "loi", "lot":
                return .front
            case "part", "chapter", "volume", "prologue", "epilogue":
                return .body
            case "afterword", "appendix", "bibliography", "colophon", "endnotes",
                 "footnotes", "glossary", "index", "notes":
                return .back
            default:
                continue
            }
        }
        return nil
    }

    /// The EPUB3 landmarks vocabulary, mapped to matters.
    static func landmarkMatter(_ raw: String) -> Matter? {
        let tokens = raw.lowercased().split(whereSeparator: \.isWhitespace)
        if tokens.contains("cover") { return .cover }
        if tokens.contains("bodymatter") { return .body }
        if tokens.contains("backmatter") { return .back }
        if tokens.contains("frontmatter") { return .front }
        for token in tokens {
            switch token {
            case "titlepage", "toc", "copyright-page": return .front
            default: continue
            }
        }
        return nil
    }

    /// The EPUB2 guide vocabulary, mapped to matters.
    static func guideMatter(_ raw: String) -> Matter? {
        switch raw.trimmed.lowercased() {
        case "text": return .body
        case "cover": return .cover
        case "title-page", "toc", "copyright-page", "acknowledgements",
             "acknowledgments", "dedication", "epigraph", "foreword", "preface",
             "loi", "lot":
            return .front
        case "bibliography", "glossary", "index", "notes", "colophon": return .back
        default: return nil
        }
    }

    /// The document's own `epub:type`, taken from `<body>` or the first
    /// `<section>` in its first 8 KB.
    static func documentEpubType(_ document: String) -> String? {
        let scan = String(document.prefix(documentTypeScanLimit))
        for tag in ["body", "section"] {
            if let range = tagBodyRange(named: tag, in: scan),
               let type = attributeValue("epub:type", in: range) {
                return type
            }
        }
        return nil
    }

    /// A cover wrapper: an image and almost no visible text (Gutenberg's
    /// `wrap0000.html`).
    static func isCoverByShape(_ document: String) -> Bool {
        guard let body = bodyContent(document) else { return false }
        guard body.range(of: "<img", options: .caseInsensitive) != nil
            || body.range(of: "<svg", options: .caseInsensitive) != nil
        else { return false }
        let text = cleanText(String(body)) ?? ""
        return text.count < coverShapeTextLimit
    }

    /// The inner text of the document's `<body>`, or `nil` when it has none.
    static func bodyContent(_ document: String) -> Substring? {
        guard let open = document.range(of: "<body", options: .caseInsensitive) else { return nil }
        guard let close = document.range(of: ">", range: open.upperBound..<document.endIndex)
        else { return nil }
        if let end = document.range(
            of: "</body", options: .caseInsensitive, range: close.upperBound..<document.endIndex
        ) {
            return document[close.upperBound..<end.lowerBound]
        }
        return document[close.upperBound...]
    }

    /// The body of the first `<name …>` tag at or after the start.
    private static func tagBodyRange(named name: String, in text: String) -> Substring? {
        var cursor = text.startIndex
        while let open = text.range(
            of: "<" + name, options: .caseInsensitive, range: cursor..<text.endIndex
        ) {
            let after = open.upperBound
            if after == text.endIndex || text[after].isWhitespace
                || text[after] == ">" || text[after] == "/" {
                guard let close = text.range(of: ">", range: after..<text.endIndex) else {
                    return nil
                }
                return text[after..<close.lowerBound]
            }
            cursor = open.upperBound
        }
        return nil
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
        // Ebookmaker wraps a cover page's `<title>` in literal quotes
        // (`<title>"Cover"</title>`); one pair around the whole title is
        // punctuation, not part of the name. A title that quotes itself
        // (`"A" and "B"`) keeps its marks.
        let quoted = (collapsed.hasPrefix("\"") && collapsed.hasSuffix("\""))
            || (collapsed.hasPrefix("\u{201C}") && collapsed.hasSuffix("\u{201D}"))
        if quoted, collapsed.count >= 2 {
            let inner = String(collapsed.dropFirst().dropLast())
            let innerHasQuotes = collapsed.hasPrefix("\"")
                ? inner.contains("\"")
                : inner.contains("\u{201C}") || inner.contains("\u{201D}")
            if !innerHasQuotes {
                return inner.isEmpty ? nil : inner
            }
        }
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

    /// Whether a manifest item can be a chapter: a content document that is
    /// not the nav. The manifest's media type and `properties` decide; the
    /// href extension is only consulted when the media type is missing, so a
    /// chapter named `navarre.xhtml` is kept while an NCX or the nav
    /// document itself is dropped.
    static func isContentItem(_ item: ManifestItem) -> Bool {
        if let mediaType = item.mediaType, !mediaType.isEmpty {
            let lower = mediaType.lowercased()
            guard lower == "application/xhtml+xml" || lower == "text/html" else { return false }
            let properties = item.properties?.split(whereSeparator: \.isWhitespace) ?? []
            return !properties.contains("nav")
        }
        let lower = item.href.lowercased()
        return [".xhtml", ".html", ".htm", ".xml"].contains { lower.hasSuffix($0) }
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
