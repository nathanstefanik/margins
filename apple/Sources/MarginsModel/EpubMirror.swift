import Foundation
import MarginsCore

/// An eviction-proof local copy of EPUBs opened or imported on this
/// device. Lives under Application Support, outside the iCloud library
/// tree, and is excluded from backup. The filename is the content-hash
/// book id, so a copy is self-validating.
public struct EpubMirror: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func path(for bookId: String) -> String {
        root.appendingPathComponent("\(bookId).epub").path
    }

    public func has(_ bookId: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: bookId))
    }

    public func fill(bookId: String, from sourcePath: String) throws {
        if has(bookId) { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".\(bookId).tmp")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(atPath: sourcePath, toPath: tmp.path)
        let hash = try Library.contentID(ofFile: tmp.path)
        guard hash == bookId else {
            try? FileManager.default.removeItem(at: tmp)
            throw CoreError.library("mirror hash mismatch")
        }
        var dest = URL(fileURLWithPath: path(for: bookId))
        try FileManager.default.moveItem(at: tmp, to: dest)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dest.setResourceValues(values)
    }

    public func remove(_ bookId: String) {
        try? FileManager.default.removeItem(atPath: path(for: bookId))
    }
}
