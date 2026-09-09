import Testing
import MarginsModel

@Suite("ReaderResource")
struct ReaderResourceTests {
    @Test("the five fixed resources resolve, with or without a leading slash")
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
        ]
        for path in hostile {
            #expect(ReaderResource(path: path) == nil, "expected '\(path)' to be rejected")
        }
    }
}
