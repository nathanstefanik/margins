import Foundation
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

    /// `ReaderPalette` is the single source of truth for the papers, but
    /// the webview side keeps its own copies — `READER_THEMES` in
    /// reader.js and the pre-paint rules in reader.html. This pins all
    /// three so a palette edit can never drift.
    @Test("the reader resources carry ReaderPalette's hexes verbatim")
    func paletteStaysInSyncWithResources() throws {
        let js = try #require(
            ReaderResource.readerJS.bundledURL
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) },
            "bundled reader.js could not be read"
        )
        let html = try #require(
            ReaderResource.readerHTML.bundledURL
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) },
            "bundled reader.html could not be read"
        )

        for theme in ReaderTheme.allCases {
            let name = theme.rawValue
            let palette = theme.palette

            let jsEntry = try #require(
                js.range(
                    of: "\(name):\\s*\\{[^}]*\\}",
                    options: .regularExpression
                ).map { js[$0] },
                "reader.js is missing a READER_THEMES entry for \(name)"
            )
            #expect(jsEntry.contains("background: \"\(palette.background.hex)\""))
            #expect(jsEntry.contains("ink: \"\(palette.ink.hex)\""))
            #expect(jsEntry.contains("secondaryInk: \"\(palette.secondaryInk.hex)\""))

            let htmlRule = try #require(
                html.range(
                    of: "html\\.reader-\(name)[^{]*\\{[^}]*\\}",
                    options: .regularExpression
                ).map { html[$0] },
                "reader.html is missing a pre-paint rule for \(name)"
            )
            #expect(htmlRule.contains("background: \(palette.background.hex)"))
            #expect(htmlRule.contains("color: \(palette.ink.hex)"))
        }

        // The per-paper highlight fills and blend modes in
        // READER_HIGHLIGHTS are a design constant, not derivable from the
        // palette — pin the literals so an edit stays deliberate.
        let highlights: [String: (String, String)] = [
            "light": ("rgba(255, 213, 79, 0.45)", "multiply"),
            "sepia": ("rgba(226, 176, 74, 0.40)", "multiply"),
            "dark": ("rgba(214, 170, 90, 0.26)", "normal"),
            "night": ("rgba(190, 150, 80, 0.20)", "normal"),
        ]
        let highlightsBlock =
            try #require(js.range(of: "READER_HIGHLIGHTS")).upperBound..<js.endIndex
        for theme in ReaderTheme.allCases {
            let entry = try #require(
                js.range(
                    of: "\(theme.rawValue):\\s*\\{[^}]*\\}",
                    options: .regularExpression,
                    range: highlightsBlock
                ).map { js[$0] },
                "reader.js is missing a READER_HIGHLIGHTS entry for \(theme.rawValue)"
            )
            let expected = highlights[theme.rawValue]!
            #expect(entry.contains("fill: \"\(expected.0)\""))
            #expect(entry.contains("blend: \"\(expected.1)\""))
        }
    }

}
