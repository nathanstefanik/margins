import Foundation

/// The fixed set of resources served over `margins-reader://`.
///
/// The scheme handler serves exactly these five flat names; resolution is
/// intentionally strict so traversal, nested paths, and unknown names never
/// reach the filesystem or the bridge.
public enum ReaderResource: String, CaseIterable, Sendable {
    case readerHTML = "reader.html"
    case readerJS = "reader.js"
    case epubJS = "epub.min.js"
    case jszipJS = "jszip.min.js"
    case bookEpub = "book.epub"

    /// Resolves a `margins-reader://` URL path to a resource. Accepts an
    /// optional leading slash and nothing else: any nested path, traversal
    /// component, percent escape, or unknown name is rejected.
    public init?(path: String) {
        var name = path
        if name.hasPrefix("/") {
            name.removeFirst()
        }
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains(".."),
              !name.contains("\\"),
              !name.contains("%"),
              let resource = ReaderResource(rawValue: name)
        else {
            return nil
        }
        self = resource
    }

    /// File name (without extension) inside the vendored reader directory.
    public var fileName: String {
        let raw = rawValue
        guard let dot = raw.lastIndex(of: ".") else { return raw }
        return String(raw[raw.startIndex..<dot])
    }

    /// File extension inside the vendored reader directory.
    public var fileExtension: String {
        let raw = rawValue
        guard let dot = raw.lastIndex(of: ".") else { return "" }
        return String(raw[raw.index(after: dot)...])
    }

    public var mimeType: String {
        switch self {
        case .readerHTML: "text/html"
        case .readerJS, .epubJS, .jszipJS: "text/javascript"
        case .bookEpub: "application/epub+zip"
        }
    }

    public var textEncodingName: String? {
        switch self {
        case .readerHTML, .readerJS, .epubJS, .jszipJS: "utf-8"
        case .bookEpub: nil
        }
    }
}
