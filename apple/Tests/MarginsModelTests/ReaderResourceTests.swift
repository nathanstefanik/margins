import MarginsModel
import Testing

@Suite("ReaderResource")
struct ReaderResourceTests {
    @Test("the seven fixed resources resolve, with or without a leading slash")
    func validPathsResolve() {
        for resource in ReaderResource.allCases {
            #expect(ReaderResource(path: "/\(resource.rawValue)") == resource)
            #expect(ReaderResource(path: resource.rawValue) == resource)
        }
    }

    @Test("traversal, nested, unknown, and empty paths are rejected")
    func hostilePathsAreRejected() {
        let hostile = [
            "",
            "/",
            "/..",
            "/../reader.html",
            "/reader.html/../reader.js",
            "/a/b/reader.html",
            "/unknown.js",
            "reader.html/extra",
            "/%2e%2e/reader.html",
            "/etc/passwd",
            "/AtkinsonHyperlegibleNext[wght].ttf",
            "/AtkinsonHyperlegibleNext%5Bwght%5D.ttf",
            "/AtkinsonHyperlegibleNext-OFL.txt",
        ]
        for path in hostile {
            #expect(ReaderResource(path: path) == nil, "expected '\(path)' to be rejected")
        }
    }

    @Test("the bundled font files serve as ttf font data")
    func fontsServeAsTtf() {
        #expect(ReaderResource.atkinson.mimeType == "font/ttf")
        #expect(ReaderResource.atkinsonItalic.mimeType == "font/ttf")
        #expect(ReaderResource.atkinson.textEncodingName == nil)
        #expect(ReaderResource.atkinsonItalic.textEncodingName == nil)
        #expect(ReaderResource.atkinson.fileName == "AtkinsonHyperlegibleNext")
        #expect(ReaderResource.atkinsonItalic.fileName == "AtkinsonHyperlegibleNext-Italic")
    }
}
