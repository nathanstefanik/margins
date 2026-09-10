import Foundation
@testable import MarginsCore
import Testing

/// Translated from `crates/margins-core/src/marks.rs`'s test module. The
/// marks section is the one place where byte identity is the contract:
/// editing one mark must not rewrite its neighbours, and content the parser
/// cannot understand must survive a round trip untouched.
@Suite("Marks")
struct MarksTests {
    /// A mark at canonical second precision — `at=` is written with
    /// `SecondsFormat::Secs`, so a sub-second value would never round-trip.
    private func mark(
        _ id: String, percent: Double? = nil, quote: String = "", body: String = ""
    ) -> Mark {
        Mark(
            id: id,
            cfi: "epubcfi(/6/14!/4/2)",
            at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            percent: percent,
            quote: quote,
            body: body
        )
    }

    @Test("a canonical block round-trips through the parser")
    func canonicalBlockRoundTrips() throws {
        let original = mark(
            "b01j8q3k2m", percent: 38.2, quote: "quoted selection", body: "The quick thought."
        )
        let block = Marks.canonicalBlock(original)
        let items = Marks.parseSection("\(Marks.sentinel)\n\n\(block)\n")
        let parsed = Marks.marks(items)

        #expect(parsed.count == 1)
        #expect(parsed.first == original)

        // Canonical bytes are stable: serialize(parse(canonical)) == canonical.
        guard case let .mark(_, raw) = try #require(items.first) else {
            Issue.record("expected a mark block")
            return
        }
        #expect(raw == block)
    }

    @Test("a highlight without a body and a note without a quote both round-trip")
    func highlightsAndNotesRoundTrip() {
        let highlight = mark("b01j8q3k2m", quote: "just a quote")
        let note = mark("b01j8q3k3n", body: "thought only")
        let text = """
        \(Marks.sentinel)

        \(Marks.canonicalBlock(highlight))

        \(Marks.canonicalBlock(note))

        """
        let parsed = Marks.marks(Marks.parseSection(text))

        #expect(parsed.count == 2)
        #expect(parsed[0].quote == "just a quote")
        #expect(parsed[0].body.isEmpty)
        #expect(parsed[1].quote.isEmpty)
        #expect(parsed[1].body == "thought only")
    }

    @Test("unparsable blocks are preserved verbatim")
    func unparsableBlocksArePreserved() {
        let section = """
        \(Marks.sentinel)

        some stray text

        <!-- margins:mark id= no-at -->
        > broken

        \(Marks.canonicalBlock(mark("b01j8q3k4p", quote: "q", body: "b")))

        """
        let items = Marks.parseSection(section)

        #expect(items.count == 3)
        #expect(items[0] == .raw("some stray text"))
        #expect(items[1].rawText.contains("> broken"))
        if case .mark = items[2] {} else { Issue.record("expected a mark block last") }

        // Everything survives a re-serialization.
        let reparsed = Marks.parseSection(Marks.serialize(items))
        #expect(Marks.marks(reparsed).count == 1)
        #expect(reparsed.count == items.count)
    }

    @Test("a sentinel inside a mark body is just text")
    func sentinelInsideABodyIsText() {
        let section = """
        \(Marks.sentinel)

        \(Marks.canonicalBlock(mark("b01j8q3k5q", body: "see \(Marks.sentinel) below")))

        """
        let parsed = Marks.marks(Marks.parseSection(section))
        #expect(parsed.count == 1)
        #expect(parsed[0].body.contains(Marks.sentinel))
    }

    @Test("untouched blocks keep their bytes through update and delete")
    func untouchedBlocksKeepTheirBytes() {
        let a = mark("baaaaaaaaaa", quote: "quote a", body: "body a")
        let b = mark("bbbbbbbbbbb", quote: "quote b", body: "body b")
        let c = mark("ccccccccccc", quote: "quote c", body: "body c")
        var items: [MarkItem] = []
        Marks.append(a, to: &items)
        Marks.append(b, to: &items)
        Marks.append(c, to: &items)

        // Update the middle one; a and c keep their bytes.
        var edited = b
        edited.body = "edited body b"
        #expect(Marks.update(edited, in: &items))
        #expect(items.map(\.rawText)[0].contains("body a"))
        #expect(items.map(\.rawText)[1].contains("edited body b"))
        #expect(items.map(\.rawText)[2].contains("body c"))

        // Delete the first; c still keeps its bytes.
        #expect(Marks.delete(id: a.id, from: &items))
        #expect(items.count == 2)
        #expect(items.map(\.rawText)[1].contains("body c"))
        #expect(!Marks.delete(id: "zzzzzzzzzzz", from: &items))
    }

    @Test("ids are time-ordered and well-formed")
    func idsAreTimeOrdered() async throws {
        let first = Marks.newMarkID()
        try await Task.sleep(for: .milliseconds(3))
        let second = Marks.newMarkID()

        #expect(first.count == 10)
        #expect(second.count == 10)
        #expect(first.allSatisfy { "0123456789abcdefghjkmnpqrstvwxyz".contains($0) })
        #expect(first < second, "ids must sort by time: \(first) !< \(second)")
    }

    @Test("quoted attribute values parse with spaces and parentheses")
    func quotedAttributesParse() {
        let section = """
        \(Marks.sentinel)

        <!-- margins:mark id=b01j8q3k6r cfi="epubcfi(/6/14!/4/2/10,/1:0,/1:42)" \
        at=2026-09-05T14:02:11Z percent=38.2 -->
        > q

        b

        """
        let parsed = Marks.marks(Marks.parseSection(section))
        #expect(parsed.count == 1)
        #expect(parsed[0].cfi == "epubcfi(/6/14!/4/2/10,/1:0,/1:42)")
        #expect(parsed[0].percent == 38.2)
    }

    @Test("splitBody finds the first sentinel only")
    func splitBodyFindsTheFirstSentinel() {
        let split = Marks.splitBody("prose\n\n\(Marks.sentinel)\n\nmark stuff")
        #expect(split.body == "prose")
        #expect(split.section == "mark stuff")

        let none = Marks.splitBody("just prose")
        #expect(none.body == "just prose")
        #expect(none.section == nil)
    }

    @Test("reading order puts percentless marks last")
    func readingOrderPutsPercentlessMarksLast() {
        let sorted = Marks.sortedByReadingOrder([
            mark("bbbbbbbbbbb", quote: "q", body: "b"),
            mark("ccccccccccc", percent: 51.0, quote: "q", body: "b"),
            mark("aaaaaaaaaaa", percent: 38.0, quote: "q", body: "b"),
        ])
        #expect(sorted.map(\.id) == ["aaaaaaaaaaa", "ccccccccccc", "bbbbbbbbbbb"])
    }

    @Test("adversarial input never crashes and stays lossless")
    func adversarialInputStaysLossless() {
        let nasty = [
            "",
            "\n\n\n",
            "<!-- margins:mark -->",
            "<!-- margins:mark id=x -->",
            "<!-- margins:mark id=x at=garbage -->",
            "<!-- margins:mark id=\"\" cfi=\"unterminated",
            "<!-- margins:mark percent=abc at=2026-09-05T10:00:00Z id=xx -->\n> q\n\nb",
            "stray --> fragments <!-- without\nany comment structure",
            "<!-- margins:mark id=yy at=2026-09-05T10:00:00Z -->\n> \n\n> nested\n\nbody > arrow",
            "unicode: 中文 — em—dash … emoji 📚\n\n"
                + "<!-- margins:mark id=zz at=2026-09-05T10:00:00Z percent=100 -->\n> 引用\n\n笔记",
        ]
        for section in nasty {
            let items = Marks.parseSection(section)
            // Whatever was parsed must survive a re-serialization round trip
            // with the same marks.
            let round = Marks.parseSection(Marks.serialize(items))
            #expect(Marks.marks(round) == Marks.marks(items), "section: \(section)")
        }
    }

    @Test("a cfi containing a comment end survives")
    func commentEndInsideACfiSurvives() {
        // `-->` inside a quoted cfi is unusual but must not break parsing:
        // the line-suffix strip takes the final comment end.
        let section = "<!-- margins:mark id=aa at=2026-09-05T10:00:00Z cfi=\"epubcfi(a-->b)\" -->"
            + "\n> q\n\nb\n"
        let parsed = Marks.marks(Marks.parseSection(section))
        #expect(parsed.count == 1)
        #expect(parsed[0].cfi == "epubcfi(a-->b)")
    }

    @Test("a percent renders with one decimal place")
    func percentRendersWithOneDecimal() {
        let block = Marks.canonicalBlock(mark("b01j8q3k7s", percent: 100, quote: "q"))
        #expect(block.contains(" percent=100.0 -->"))
        #expect(!Marks.canonicalBlock(mark("b01j8q3k8t", quote: "q")).contains("percent="))
    }
}

@Suite("AppConfig")
struct AppConfigTests {
    /// Translated from `config.rs`. The Rust tests drove the real process
    /// environment behind a mutex; these use an explicit data directory
    /// instead, which is what the apps pass and what keeps the suite
    /// parallel-safe.
    private func temporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-config-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("the library root defaults inside the data directory")
    func libraryRootDefaultsInsideTheDataDirectory() throws {
        let base = try temporaryDirectory()
        let dataDir = base.appendingPathComponent("data")

        let config = try AppConfig(dataDir: dataDir)
        #expect(config.dataDir == dataDir)
        #expect(config.libraryRoot == dataDir.appendingPathComponent("library"))
        #expect(FileManager.default.fileExists(atPath: dataDir))
    }

    @Test("setting the library root persists it and reloads")
    func setLibraryRootPersistsAndReloads() throws {
        let base = try temporaryDirectory()
        let dataDir = base.appendingPathComponent("data")
        let libraryRoot = base.appendingPathComponent("external-lib")

        var config = try AppConfig(dataDir: dataDir)
        try config.setLibraryRoot(libraryRoot)
        #expect(config.libraryRoot == libraryRoot)
        #expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("config.json")))
        // The chosen directory is created, not merely recorded.
        #expect(FileManager.default.fileExists(atPath: libraryRoot))

        let reloaded = try AppConfig(dataDir: dataDir)
        #expect(reloaded.libraryRoot == libraryRoot)
    }

    @Test("config.json keeps the key the Rust core wrote")
    func configJSONKeepsItsKey() throws {
        let base = try temporaryDirectory()
        let dataDir = base.appendingPathComponent("data")
        var config = try AppConfig(dataDir: dataDir)
        try config.setLibraryRoot(base.appendingPathComponent("chosen"))

        let raw = try String(
            contentsOf: URL(fileURLWithPath: dataDir.appendingPathComponent("config.json")),
            encoding: .utf8
        )
        #expect(raw.contains("\"library_root\""))

        // And a config.json written by the Rust core loads.
        let other = base.appendingPathComponent("other")
        try #"{"library_root":"\#(other)"}"#
            .write(toFile: dataDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(try AppConfig(dataDir: dataDir).libraryRoot == other)
    }

    @Test("an empty config.json falls back to the default root")
    func emptyConfigFallsBack() throws {
        let base = try temporaryDirectory()
        let dataDir = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try "{}".write(
            toFile: dataDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
        )

        let config = try AppConfig(dataDir: dataDir)
        #expect(config.libraryRoot == dataDir.appendingPathComponent("library"))
    }
}
