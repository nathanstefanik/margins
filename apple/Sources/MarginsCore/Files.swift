import Foundation

// Thin filesystem layer. Every read and write in the core goes through here
// so failures carry a `CoreError` instead of a bare `NSError`, and so Phase
// 2 step 5 has one place to add `NSFileCoordinator` for the iCloud case.
enum Files {
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return found && !directory.boolValue
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return found && directory.boolValue
    }

    static func createDirectory(_ path: String) throws {
        try wrapping("could not create \(path)") {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
        }
    }

    static func read(_ path: String) throws -> String {
        try wrapping("could not read \(path)") {
            try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        }
    }

    static func readData(_ path: String) throws -> Data {
        try wrapping("could not read \(path)") {
            try Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    static func write(_ text: String, to path: String) throws {
        try writeData(Data(text.utf8), to: path)
    }

    static func writeData(_ data: Data, to path: String) throws {
        try wrapping("could not write \(path)") {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Directory entries as full paths, in a stable order. `FileManager`
    /// makes no ordering promise, and the library scan and note count both
    /// need determinism.
    static func contents(ofDirectory path: String) throws -> [String] {
        let names = try wrapping("could not list \(path)") {
            try FileManager.default.contentsOfDirectory(atPath: path)
        }
        return names.sorted().map { path.appendingPathComponent($0) }
    }

    static func remove(_ path: String) throws {
        try wrapping("could not remove \(path)") {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    static func rename(_ path: String, to destination: String) throws {
        try wrapping("could not move \(path)") {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        }
    }

    static func modificationDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private static func wrapping<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw CoreError.io("io error: \(what): \(error.localizedDescription)")
        }
    }
}
