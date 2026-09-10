import Foundation
@testable import MarginsCore
import Testing

/// The YAML frontmatter codec (docs/apple-only-plan.md Phase 2 step 3).
///
/// `serde_yaml` decided how every note file on disk is spelled, so the
/// scalar table below is not hand-reasoned: it is the real output of
/// `serde_yaml::to_string` for each input, captured from the Rust core
/// before it was deleted. Getting one of these wrong means writing a note
/// file that reads back as a number, or churning every file on first save.
@Suite("Frontmatter")
struct FrontmatterTests {
    @Test("scalars are spelled exactly as serde_yaml spelled them")
    func scalarsMatchSerdeYAML() {
        for (value, expected) in Self.scalarCases {
            #expect(Frontmatter.scalar(value) == expected, "input: \(value)")
        }
    }

    @Test("every scalar reads back as itself")
    func scalarsRoundTrip() throws {
        for (value, _) in Self.scalarCases {
            let yaml = """
            book_id: abc
            chapter_key: '001'
            chapter_index: 0
            chapter_title: \(Frontmatter.scalar(value))
            chapter_href: OEBPS/one.xhtml
            kind: summary
            word_count: 0
            """
            #expect(try Frontmatter.decode(yaml).chapterTitle == value, "input: \(value)")
        }
    }

    @Test("a line break survives even though serde_yaml would use a block scalar")
    func lineBreaksRoundTrip() throws {
        // The one documented departure from serde_yaml's spelling: it emits
        // `|-` blocks, this emits a double-quoted scalar. Both are valid
        // YAML; what matters is that the value survives.
        let value = "multi\nline"
        #expect(Frontmatter.scalar(value) == "\"multi\\nline\"")
        let yaml = """
        book_id: abc
        chapter_key: '001'
        chapter_index: 0
        chapter_title: \(Frontmatter.scalar(value))
        chapter_href: OEBPS/one.xhtml
        kind: summary
        word_count: 0
        """
        #expect(try Frontmatter.decode(yaml).chapterTitle == value)
    }

    @Test("a block scalar written by serde_yaml still parses")
    func blockScalarsParse() throws {
        let yaml = """
        book_id: abc
        chapter_key: '001'
        chapter_index: 0
        chapter_title: |-
          multi
          line
        chapter_href: OEBPS/one.xhtml
        kind: summary
        word_count: 0
        """
        #expect(try Frontmatter.decode(yaml).chapterTitle == "multi\nline")
    }

    // MARK: Golden files

    @Test("frontmatter captured from the Rust core round-trips byte for byte")
    func goldenFrontmatterRoundTrips() throws {
        for name in ["frontmatter-full", "frontmatter-bare"] {
            let raw = try Fixtures.text("notes/\(name).yaml")
            let decoded = try Frontmatter.decode(raw)
            #expect(Frontmatter.encode(decoded) == raw, "fixture: \(name)")
        }
    }

    @Test("the captured frontmatter decodes to the right values")
    func goldenFrontmatterValues() throws {
        let full = try Frontmatter.decode(Fixtures.text("notes/frontmatter-full.yaml"))
        #expect(full.bookId == "a1b2c3d4e5f6a1b2c3d4e5f6")
        #expect(full.chapterKey == "003")
        #expect(full.chapterIndex == 2)
        // A title serde_yaml had to quote, because of the `: `.
        #expect(full.chapterTitle == "A Title: With / Punctuation!")
        #expect(full.epubCfi == "epubcfi(/6/6!/4/2/1:0)")
        #expect(full.kind == "summary")
        #expect(full.createdAt == RFC3339.date(from: "2026-08-29T12:00:00Z"))
        #expect(full.updatedAt == RFC3339.date(from: "2026-08-29T12:30:00Z"))

        let bare = try Frontmatter.decode(Fixtures.text("notes/frontmatter-bare.yaml"))
        // Optional fields are omitted, not nulled.
        #expect(bare.epubCfi == nil)
        #expect(bare.createdAt == nil)
        #expect(bare.updatedAt == nil)
        // A numeric-looking title stays a string.
        #expect(bare.chapterTitle == "123")
    }

    @Test("a truncated frontmatter fails rather than losing a note's identity")
    func truncatedFrontmatterFails() {
        #expect(throws: CoreError.self) {
            try Frontmatter.decode("book_id: abc\nchapter_key: '001'\n")
        }
    }

    @Test("unknown keys are ignored")
    func unknownKeysAreIgnored() throws {
        let yaml = """
        book_id: abc
        chapter_key: '001'
        chapter_index: 0
        chapter_title: One
        chapter_href: OEBPS/one.xhtml
        kind: summary
        word_count: 4
        invented_by_a_future_version: 7
        """
        #expect(try Frontmatter.decode(yaml).wordCount == 4)
    }

    /// `serde_yaml::to_string` output for each input, captured from the Rust
    /// core (`examples/probe_yaml.rs`).
    private static let scalarCases: [(String, String)] = [
        ("Introduction", "Introduction"),
        ("The Market", "The Market"),
        ("A Title: With / Punctuation!", "'A Title: With / Punctuation!'"),
        ("003", "'003'"),
        ("123", "'123'"),
        ("0", "'0'"),
        ("1.5", "'1.5'"),
        ("true", "'true'"),
        ("false", "'false'"),
        ("null", "'null'"),
        ("~", "'~'"),
        ("yes", "yes"),
        ("no", "no"),
        ("on", "on"),
        ("off", "off"),
        ("Null", "'Null'"),
        ("TRUE", "'TRUE'"),
        ("", "''"),
        (" leading", "' leading'"),
        ("trailing ", "'trailing '"),
        ("-dash", "-dash"),
        ("- dash", "'- dash'"),
        ("?q", "?q"),
        (":colon", ":colon"),
        (",comma", "',comma'"),
        ("[bracket", "'[bracket'"),
        ("]bracket", "']bracket'"),
        ("{brace", "'{brace'"),
        ("}brace", "'}brace'"),
        ("#hash", "'#hash'"),
        ("&amp", "'&amp'"),
        ("*star", "'*star'"),
        ("!bang", "'!bang'"),
        ("|pipe", "'|pipe'"),
        (">gt", "'>gt'"),
        ("'quote", "'''quote'"),
        ("\"dquote", "'\"dquote'"),
        ("%pct", "'%pct'"),
        ("@at", "'@at'"),
        ("`tick", "'`tick'"),
        ("a: b", "'a: b'"),
        ("a:b", "a:b"),
        ("a #c", "'a #c'"),
        ("a#c", "a#c"),
        ("ends:", "'ends:'"),
        ("tab\there", "\"tab\\there\""),
        ("epubcfi(/6/6!/4/2/1:0)", "epubcfi(/6/6!/4/2/1:0)"),
        ("OEBPS/chapter1.xhtml", "OEBPS/chapter1.xhtml"),
        ("2026-08-29T12:00:00Z", "2026-08-29T12:00:00Z"),
        ("2026-08-29", "2026-08-29"),
        ("12:30", "12:30"),
        ("e5", "e5"),
        ("0x1f", "'0x1f'"),
        ("0o17", "'0o17'"),
        (".inf", "'.inf'"),
        (".nan", "'.nan'"),
        ("Café — naïve 中文 📚", "Café — naïve 中文 📚"),
        ("hello world", "hello world"),
        ("Chapter II. He Gets Rid Of His Eldest Son", "Chapter II. He Gets Rid Of His Eldest Son"),
        ("  ", "'  '"),
        ("\ttab-start", "\"\\ttab-start\""),
        ("a  b", "a  b"),
        ("-", "'-'"),
        ("--", "--"),
        ("5e3", "'5e3'"),
        ("+3", "'+3'"),
        ("1_000", "1_000"),
    ]
}
