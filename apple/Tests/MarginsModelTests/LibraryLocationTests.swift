import Foundation
import MarginsCore
import MarginsModel
import Testing

@Suite("LibraryLocation")
struct LibraryLocationTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-location-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("stagedCopy snapshots a picked file into a readable staging path")
    func stagedCopy() throws {
        let location = LibraryLocation()
        let picked = tempDirectory().appendingPathComponent("book.epub")
        try Data("epub-bytes".utf8).write(to: picked)
        let staged = try location.stagedCopy(of: picked)
        #expect(staged.lastPathComponent == "book.epub")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "epub-bytes")
    }

    @Test("requestDownload ignores paths that are not ubiquitous items")
    func requestDownloadIsSafe() {
        // A plain local path: the daemon refuses, and the call must not
        // throw — errors are the caller's to ignore.
        LibraryLocation.requestDownload("/nonexistent/file.epub")
        LibraryLocation.requestDownload(tempDirectory().path)
    }
}
