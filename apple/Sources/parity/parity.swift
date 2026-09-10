// Parity driver for the Swift core (docs/apple-only-plan.md Phase 2 step 6).
//
// Runs the byte-for-byte same scripted sequence as
// `crates/margins-core/examples/parity.rs` against a working library
// directory and writes the same snapshot tree + reports;
// `scripts/parity-compare.py` proves the outputs agree. Deleted with the
// Rust core in step 7.
//
// Usage:
//   parity --library <dir> --out <dir> [--fixture <epub>]

import Foundation
import MarginsKernel

/// Query 1 hits note content; queries 2 and 3 derive from the book's own
/// metadata (first title word, last author word) so the search leg is
/// meaningful for any fixture. Must mirror the Rust driver.
func searchQueries(meta: BookMeta) -> [String] {
    [
        "xylophone",
        meta.title.split(separator: " ").first.map(String.init) ?? "",
        meta.author.split(separator: " ").last.map(String.init) ?? "",
    ]
}

/// The kernel's path-join helper is internal; the driver carries its own.
private extension String {
    func joining(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}

/// JSONSerializable-friendly wrapper: JSONSerialization rejects Swift
/// optionals, so absent values become explicit nulls.
func jsonValue(_ optional: String?) -> Any {
    optional ?? NSNull()
}

func jsonValue(_ optional: Double?) -> Any {
    optional ?? NSNull()
}

func parseArgs() -> (library: String, out: String, fixture: String?) {
    var args: [String: String] = [:]
    var iterator = CommandLine.arguments.makeIterator()
    _ = iterator.next()
    while let key = iterator.next() {
        guard key.hasPrefix("--"), let value = iterator.next() else {
            fatalError("unknown or dangling argument: \(key)")
        }
        args[String(key.dropFirst(2))] = value
    }
    guard let library = args["library"], let out = args["out"] else {
        fatalError("usage: parity --library <dir> --out <dir> [--fixture <epub>]")
    }
    return (library, out, args["fixture"])
}

func createDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func contents(ofDirectory path: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        .map { path.joining($0) }
}

func writeData(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path))
}

func copyTree(from: String, to: String) throws {
    try createDirectory(to)
    for entry in try contents(ofDirectory: from) {
        let target = to.joining((entry as NSString).lastPathComponent)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: entry, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try copyTree(from: entry, to: target)
        } else {
            try FileManager.default.copyItem(atPath: entry, toPath: target)
        }
    }
}

func snapshot(library: String, out: String, name: String) throws {
    try copyTree(from: library, to: out.joining("snapshots").joining(name))
}

func writeReport(_ object: Any, out: String, name: String) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try createDirectory(out.joining("report"))
    try writeData(data, to: out.joining("report").joining(name))
}

func resolveChapter(library: Library, bookId: String, key: String) throws -> ChapterMeta {
    let meta = try library.getBook(id: bookId)
    guard let chapter = meta.chapters.first(where: { $0.key == key }) else {
        fatalError("unknown chapter key: \(key)")
    }
    return chapter
}

func frontmatterFor(bookId: String, chapter: ChapterMeta, body: String) -> NoteFrontmatter {
    NoteFrontmatter(
        bookId: bookId,
        chapterKey: chapter.key,
        chapterIndex: chapter.index,
        chapterTitle: chapter.title,
        chapterHref: chapter.href,
        epubCfi: nil,
        kind: "summary",
        wordCount: Notes.countWords(body)
    )
}

func run(libraryPath: String, out: String, fixture: String?) throws {
    let library = try Library(root: libraryPath)

    if let fixture {
        _ = try library.importEpub(atPath: fixture)
        try snapshot(library: libraryPath, out: out, name: "01-import")
    }

    // list
    let summaries = try library.listBooks()
    try writeReport(
        summaries.map { summary -> [String: Any] in
            [
                "id": summary.id, "title": summary.title, "author": summary.author,
                "chapterCount": summary.chapterCount, "notesCount": summary.notesCount,
            ]
        },
        out: out, name: "catalog.json"
    )

    guard let bookId = summaries.first?.id else {
        fatalError("library must hold one book")
    }
    let meta = try library.getBook(id: bookId)
    try writeReport(
        [
            "id": meta.id, "title": meta.title, "author": meta.author,
            "language": jsonValue(meta.language), "chaptersVersion": meta.chaptersVersion,
            "cover": jsonValue(meta.cover),
            "chapters": meta.chapters.map { chapter -> [String: Any] in
                [
                    "key": chapter.key, "index": chapter.index, "title": chapter.title,
                    "href": chapter.href, "fragment": jsonValue(chapter.fragment),
                ]
            },
        ],
        out: out, name: "book.json"
    )

    // notes index
    let bookDir = library.bookDir(bookId)
    let index = try Notes.readIndex(bookDir: bookDir)
    try writeReport(
        index.chapters.map { entry -> [String: Any] in
            [
                "chapterKey": entry.chapterKey, "chapterIndex": entry.chapterIndex,
                "chapterTitle": entry.chapterTitle, "wordCount": entry.wordCount,
                "markCount": entry.markCount,
            ]
        },
        out: out, name: "notes-index.json"
    )

    // position
    guard let first = meta.chapters.first else {
        fatalError("spine is empty")
    }
    try library.writePosition(
        bookID: bookId,
        position: ReadingPosition(
            chapterKey: first.key, epubCfi: "epubcfi(/6/2!/4/2)", percent: 42.5
        )
    )
    guard let position = library.readPosition(bookID: bookId) else {
        fatalError("position must round-trip")
    }
    try writeReport(
        [
            "chapterKey": position.chapterKey, "epubCfi": jsonValue(position.epubCfi),
            "percent": position.percent,
        ],
        out: out, name: "position.json"
    )
    try snapshot(library: libraryPath, out: out, name: "02-position")

    // note
    let body =
        "First draft of the note.\n\n# A Heading\n## Sub Heading\n\nThe xylophone motif returns here."
    let chapter = try resolveChapter(library: library, bookId: bookId, key: first.key)
    _ = try Notes.saveChapterNote(
        bookDir: bookDir, chapter: chapter,
        frontmatter: frontmatterFor(bookId: bookId, chapter: chapter, body: body), body: body
    )
    library.refreshNoteIndex(bookID: bookId)
    try snapshot(library: libraryPath, out: out, name: "03-note")

    // mark a: cfi + percent
    let markA = try Notes.appendMark(
        bookDir: bookDir, chapter: chapter, cfi: "epubcfi(/6/2!/4/2)", percent: 38.2,
        quote: "an early quote", body: "an early thought"
    )
    library.refreshNoteIndex(bookID: bookId)
    try snapshot(library: libraryPath, out: out, name: "04-mark-a")

    // mark b: page-anchored, no cfi, no percent
    let markB = try Notes.appendMark(
        bookDir: bookDir, chapter: chapter, cfi: nil, percent: nil,
        quote: "a later quote", body: "a later thought"
    )
    library.refreshNoteIndex(bookID: bookId)
    try snapshot(library: libraryPath, out: out, name: "05-mark-b")

    // update mark a
    var updated = markA
    updated.body = "an edited thought"
    updated.percent = 40.0
    try Notes.updateMark(bookDir: bookDir, chapter: chapter, mark: updated)
    library.refreshNoteIndex(bookID: bookId)
    try snapshot(library: libraryPath, out: out, name: "06-mark-update")

    // delete mark b
    try Notes.deleteMark(bookDir: bookDir, chapter: chapter, id: markB.id)
    library.refreshNoteIndex(bookID: bookId)
    try snapshot(library: libraryPath, out: out, name: "07-mark-delete")

    // compile + render
    let compiled = try Compile.bookNotes(bookDir: bookDir)
    try writeReport(
        [
            "bookId": compiled.bookId,
            "chaptersWithNotes": compiled.chaptersWithNotes,
            "chapterCount": compiled.chapterCount,
            "totalWords": compiled.totalWords,
            "chapters": compiled.chapters.map { chapter -> [String: Any] in
                [
                    "chapterKey": chapter.chapterKey, "chapterIndex": chapter.chapterIndex,
                    "chapterTitle": chapter.chapterTitle, "wordCount": chapter.wordCount,
                    "marks": chapter.marks.map { mark -> [String: Any] in
                        [
                            "percent": jsonValue(mark.percent), "hasCfi": mark.cfi != nil,
                            "quote": mark.quote, "body": mark.body,
                        ]
                    },
                ]
            },
            "emptyChapters": compiled.emptyChapters.map(\.chapterKey),
        ],
        out: out, name: "compiled.json"
    )

    try writeData(
        Data(Compile.renderMarkdown(compiled).utf8),
        to: out.joining("report/render-default.md")
    )
    try writeData(
        Data(Compile.renderMarkdown(
            compiled,
            options: ExportOptions(
                includeToc: false, includeStats: false,
                includeEmptyChapters: true, demoteHeadings: false
            )
        ).utf8),
        to: out.joining("report/render-options.md")
    )

    // search
    var searchReport: [[String: Any]] = []
    for query in searchQueries(meta: meta) {
        let hits = library.searchNotes(query: query)
        searchReport.append([
            "query": query,
            "hits": hits.map { hit -> [String: Any] in
                [
                    "bookId": hit.bookId, "chapterKey": hit.chapterKey,
                    "chapterIndex": hit.chapterIndex, "chapterTitle": hit.chapterTitle,
                    "snippet": hit.snippet, "wordCount": hit.wordCount,
                    "kind": hit.kind.rawValue, "score": hit.score,
                    "snippetRanges": hit.snippetRanges.map { range -> [String: Int] in
                        ["start": range.start, "end": range.end]
                    },
                ]
            },
        ])
    }
    try writeReport(searchReport, out: out, name: "search.json")

    // clear notes
    _ = try Notes.clearBookNotes(bookDir: bookDir)
    library.refreshNoteIndex(bookID: bookId)
    try snapshot(library: libraryPath, out: out, name: "08-clear")

    // remove book
    try library.removeBook(id: bookId)
    try snapshot(library: libraryPath, out: out, name: "09-remove")
}

let args = parseArgs()
try run(libraryPath: args.library, out: args.out, fixture: args.fixture)
