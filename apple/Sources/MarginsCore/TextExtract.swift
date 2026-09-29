import Foundation
import ZIPFoundation

// Full-text extraction for the plain-file index (docs/commonplace.md
// "Extraction"): each spine chapter's XHTML is flattened into searchable
// passages — body text split at block boundaries, entities decoded,
// whitespace collapsed, overlong passages split at sentence ends.

/// One extracted passage plus the spine key of the chapter it came from.
struct ExtractedPassage: Sendable, Equatable {
    var chapterKey: String
    var text: String
}

enum TextExtractor {
    /// The extraction semantics version — an indexed book re-extracts
    /// when this differs from its manifest's `extractor`.
    static let version = 1

    /// Block-level tags that end one passage and start the next.
    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote",
        "pre", "dd", "dt", "td", "tr", "section", "article", "aside",
        "figcaption", "header", "footer", "nav", "table",
    ]

    /// Elements whose whole content is dropped, nested or not.
    private static let skipTags: Set<String> = [
        "script", "style", "head", "title", "svg",
    ]

    /// A passage longer than `splitThreshold` is repacked into chunks of
    /// at most ~`chunkTarget` characters at sentence boundaries.
    static let splitThreshold = 1_200
    static let chunkTarget = 800

    /// Extracts every chapter in spine order, opening the EPUB archive
    /// once. A missing or non-UTF-8 entry is skipped, never fatal.
    static func passages(
        epubPath: String, chapters: [ChapterMeta]
    ) throws -> [ExtractedPassage] {
        try EpubParser.withArchive(path: epubPath) { archive in
            var extracted: [ExtractedPassage] = []
            for chapter in chapters {
                guard let document = try? EpubParser.readText(archive, chapter.href)
                else { continue }
                for text in Self.passages(fromDocument: document) {
                    extracted.append(ExtractedPassage(chapterKey: chapter.key, text: text))
                }
            }
            return extracted
        }
    }

    /// Flattens one XHTML document into passages: `<body>` text (or the
    /// whole document when there is none) split at block boundaries, with
    /// `script`/`style`/`head`/`title`/`svg` content dropped, entities
    /// decoded, and whitespace collapsed. Passages with no tokens are
    /// dropped; overlong ones split at sentence ends.
    static func passages(fromDocument xhtml: String) -> [String] {
        let body = EpubParser.bodyContent(xhtml).map(String.init) ?? xhtml
        var passages: [String] = []
        var buffer = ""
        var cursor = body.startIndex
        var skipDepth = 0
        var skipTag = ""

        // Ends the current passage: whitespace collapses, tokenless
        // chunks drop, overlong ones split at sentence boundaries.
        func flush() {
            let collapsed = buffer.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            buffer.removeAll(keepingCapacity: true)
            guard !collapsed.isEmpty else { return }
            for chunk in splitLongPassage(collapsed)
            where !TextAnalyzer.tokens(chunk).isEmpty {
                passages.append(chunk)
            }
        }

        while cursor < body.endIndex {
            guard let open = body[cursor...].firstIndex(of: "<") else {
                if skipDepth == 0 {
                    buffer += EpubParser.decodeEntities(String(body[cursor...]))
                }
                break
            }
            if skipDepth == 0, open > cursor {
                buffer += EpubParser.decodeEntities(String(body[cursor..<open]))
            }
            let afterLt = body.index(after: open)
            guard afterLt < body.endIndex else { break }

            let first = body[afterLt]
            if first == "!" || first == "?" {
                // Comments, doctypes, PIs, CDATA: nothing inside counts.
                let rest = body[afterLt...]
                let end: String.Index?
                if rest.hasPrefix("!--") {
                    end = body.range(of: "-->", range: afterLt..<body.endIndex)?.upperBound
                } else if rest.hasPrefix("![CDATA[") {
                    end = body.range(of: "]]>", range: afterLt..<body.endIndex)?.upperBound
                } else {
                    end = body.range(of: ">", range: afterLt..<body.endIndex)?.upperBound
                }
                cursor = end ?? body.endIndex
                continue
            }

            let closing = first == "/"
            let nameStart = closing ? body.index(after: afterLt) : afterLt
            var nameEnd = nameStart
            while nameEnd < body.endIndex,
                body[nameEnd].isLetter || body[nameEnd].isNumber
            {
                nameEnd = body.index(after: nameEnd)
            }
            guard let gt = body.range(of: ">", range: nameEnd..<body.endIndex) else { break }
            let name = body[nameStart..<nameEnd].lowercased()
            let selfClosing = body[body.index(before: gt.lowerBound)] == "/"

            if skipDepth > 0 {
                if name == skipTag {
                    if closing {
                        skipDepth -= 1
                    } else if !selfClosing {
                        skipDepth += 1
                    }
                }
                cursor = gt.upperBound
                continue
            }
            if !closing, !selfClosing, skipTags.contains(name) {
                skipDepth = 1
                skipTag = name
            } else if name == "br" {
                buffer += " "
            } else if blockTags.contains(name) {
                flush()
            }
            cursor = gt.upperBound
        }
        flush()
        return passages
    }

    /// Closing quotes and brackets that stay with the sentence they
    /// follow ("…said.'" ends with the quote, not before it).
    private static let closingSentenceMarks: Set<Character> = [
        "\"", "'", "\u{2019}", "\u{201D}", "»", ")", "]", "\u{203A}",
    ]

    /// Splits a long passage at sentence boundaries (`. ! ? …` followed by
    /// whitespace, closing marks kept inside) into chunks of at most
    /// ~`chunkTarget` characters. A single sentence longer than the
    /// target stays whole.
    private static func splitLongPassage(_ text: String) -> [String] {
        guard text.count > splitThreshold else { return [text] }
        var sentences: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            switch text[i] {
            case ".", "!", "?", "…":
                var end = text.index(after: i)
                while end < text.endIndex, closingSentenceMarks.contains(text[end]) {
                    end = text.index(after: end)
                }
                guard end < text.endIndex, text[end].isWhitespace else {
                    i = text.index(after: i)
                    continue
                }
                sentences.append(text[start..<end])
                while end < text.endIndex, text[end].isWhitespace {
                    end = text.index(after: end)
                }
                start = end
                i = end
            default:
                i = text.index(after: i)
            }
        }
        if start < text.endIndex {
            sentences.append(text[start...])
        }

        var chunks: [String] = []
        var chunk = ""
        for sentence in sentences {
            if !chunk.isEmpty, chunk.count + sentence.count + 1 > chunkTarget {
                chunks.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            chunk += chunk.isEmpty ? String(sentence) : " " + sentence
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
}
