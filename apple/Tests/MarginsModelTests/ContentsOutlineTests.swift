import Testing
import Foundation
import MarginsCore
import MarginsModel

@Suite("ContentsOutline")
struct ContentsOutlineTests {
    private func chapter(
        key: String,
        title: String,
        matter: Matter = .body,
        level: Int = 0,
        sections: [ChapterSection] = [],
        href: String? = nil
    ) -> ChapterMeta {
        ChapterMeta(
            key: key,
            index: Int(key) ?? 0,
            title: title,
            href: href ?? "\(key).xhtml",
            matter: matter,
            level: level,
            sections: sections
        )
    }

    @Test("a Gutenberg-shaped book groups cover and front matter, headings, and numbered chapters")
    func gutenbergShapedOutline() {
        let outline = ContentsOutline.build(from: [
            chapter(key: "001", title: "Cover", matter: .cover),
            chapter(key: "002", title: "The Brothers Karamazov", matter: .front),
            chapter(key: "003", title: "PART I", sections: [
                ChapterSection(title: "PART I", level: 0),
                ChapterSection(title: "Book I. The History Of A Family", level: 1),
            ]),
            chapter(key: "004", title: "Chapter I. They Arrive At The Monastery", sections: [
                ChapterSection(title: "Chapter I. They Arrive At The Monastery", fragment: "c1", level: 2),
                ChapterSection(title: "Chapter II. He Gets Rid Of His Eldest Son", fragment: "c2", level: 2),
            ]),
            chapter(key: "005", title: "Book II. An Unfortunate Gathering", sections: [
                ChapterSection(title: "Book II. An Unfortunate Gathering", level: 1),
                ChapterSection(title: "Chapter III. The Women", fragment: "c3", level: 2),
            ]),
            chapter(key: "006", title: "Chapter IV. The Fourth", sections: [
                ChapterSection(title: "Chapter IV. The Fourth", fragment: "c4", level: 2),
            ]),
            chapter(key: "100", title: "FOOTNOTES", matter: .back),
        ])

        #expect(outline.front.count == 2)
        #expect(outline.front.allSatisfy { $0.kind == .matter })
        #expect(outline.front.map(\.title) == ["Cover", "The Brothers Karamazov"])

        #expect(outline.back.map(\.title) == ["FOOTNOTES"])
        #expect(outline.back.allSatisfy { $0.kind == .matter })

        #expect(
            outline.body.map(\.title) == [
                "PART I",
                "Book I. The History Of A Family",
                "Chapter I. They Arrive At The Monastery",
                "Chapter II. He Gets Rid Of His Eldest Son",
                "Book II. An Unfortunate Gathering",
                "Chapter III. The Women",
                "Chapter IV. The Fourth",
            ]
        )
        #expect(outline.body.map(\.kind) == [
            .heading(level: 0),
            .heading(level: 1),
            .chapter(number: 1),
            .chapter(number: 2),
            .heading(level: 1),
            .chapter(number: 3),
            .chapter(number: 4),
        ])
        #expect(outline.numberedChapterCount == 4)
    }

    @Test("an Oxford-shaped book keeps Part and Book headings above the numbered chapters")
    func oxfordShapedOutline() {
        let frontTitles = [
            "Cover", "Half Title", "Series Page", "Title Page", "Copyright",
            "Dedication", "Acknowledgements", "Contents", "Introduction",
            "Translator's Note", "Texts Used", "Select Bibliography",
            "Chronology", "Principal Characters", "From the Author",
            "A Note on the Text",
        ]
        var chapters = frontTitles.enumerated().map { index, title in
            chapter(
                key: String(format: "%03d", index + 1),
                title: title,
                matter: index == 0 ? .cover : .front
            )
        }
        chapters.append(chapter(key: "017", title: "Part One", sections: [
            ChapterSection(title: "Part One", level: 0),
            ChapterSection(title: "Book One: The Story of a Family", level: 1),
        ]))
        chapters.append(chapter(key: "018", title: "1. Fyodor Pavlovich Karamazov", sections: [
            ChapterSection(title: "1. Fyodor Pavlovich Karamazov", fragment: "c1", level: 2),
        ]))
        chapters.append(chapter(key: "019", title: "2. The Old Buffoon", sections: [
            ChapterSection(title: "2. The Old Buffoon", fragment: "c2", level: 2),
        ]))
        chapters.append(chapter(key: "020", title: "3. The Women", sections: [
            ChapterSection(title: "3. The Women", fragment: "c3", level: 2),
        ]))
        chapters.append(chapter(key: "021", title: "Explanatory Notes", matter: .back))
        chapters.append(chapter(key: "022", title: "Index", matter: .back))

        let outline = ContentsOutline.build(from: chapters)

        #expect(outline.front.count == frontTitles.count)
        #expect(outline.body.map(\.kind) == [
            .heading(level: 0),
            .heading(level: 1),
            .chapter(number: 1),
            .chapter(number: 2),
            .chapter(number: 3),
        ])
        #expect(outline.body.first?.title == "Part One")
        #expect(outline.body.first?.jumpFragment == nil)
        #expect(outline.body[2].jumpFragment == "c1")
        #expect(outline.back.map(\.title) == ["Explanatory Notes", "Index"])
        #expect(outline.numberedChapterCount == 3)
    }

    @Test("a book with no TOC numbers every row")
    func noTOCNumbersEveryRow() {
        let outline = ContentsOutline.build(from: [
            chapter(key: "001", title: "One"),
            chapter(key: "002", title: "Two"),
            chapter(key: "003", title: "Three"),
        ])
        #expect(outline.front.isEmpty)
        #expect(outline.back.isEmpty)
        #expect(outline.body.map(\.kind) == [
            .chapter(number: 1),
            .chapter(number: 2),
            .chapter(number: 3),
        ])
        #expect(outline.numberedChapters.map(\.title) == ["One", "Two", "Three"])
    }

    @Test("a body-only book leaves the groups empty")
    func bodyOnlyOutline() {
        let outline = ContentsOutline.build(from: [
            chapter(key: "001", title: "Part", sections: [ChapterSection(title: "Part", level: 0)]),
            chapter(key: "002", title: "Chapter", sections: [
                ChapterSection(title: "Chapter", fragment: "c", level: 1),
            ]),
        ])
        #expect(outline.front.isEmpty)
        #expect(outline.back.isEmpty)
        #expect(outline.body.map(\.kind) == [
            .heading(level: 0),
            .chapter(number: 1),
        ])
    }

    @Test("uniform section levels are all numbered")
    func degenerateUniformLevelsAreNumbered() {
        // Every row sits at the same depth, so none is a container: the
        // outline numbers them rather than showing a list of bare headings.
        let outline = ContentsOutline.build(from: [
            chapter(key: "001", title: "Alpha", sections: [
                ChapterSection(title: "Alpha", level: 0),
                ChapterSection(title: "Beta", level: 0),
            ]),
            chapter(key: "002", title: "Gamma", sections: [
                ChapterSection(title: "Gamma", level: 0),
            ]),
        ])
        #expect(outline.body.map(\.kind) == [
            .chapter(number: 1),
            .chapter(number: 2),
            .chapter(number: 3),
        ])
    }

    @Test("a front-matter page the TOC names several times is still one row")
    func multiSectionMatterCollapses() {
        let outline = ContentsOutline.build(from: [
            chapter(key: "001", title: "Cover", matter: .cover),
            chapter(key: "002", title: "The Brothers Karamazov", matter: .front, sections: [
                ChapterSection(title: "The Brothers Karamazov", fragment: "a", level: 0),
                ChapterSection(title: "Translated from the Russian of", fragment: "b", level: 0),
                ChapterSection(title: "The Lowell Press New York", fragment: "c", level: 0),
            ]),
            chapter(key: "003", title: "Chapter One", sections: [
                ChapterSection(title: "Chapter One", fragment: "c1", level: 0),
            ]),
        ])
        #expect(outline.front.count == 2)
        #expect(outline.front.last?.title == "The Brothers Karamazov")
        #expect(outline.front.last?.jumpFragment == "a")
        #expect(outline.numberedChapterCount == 1)
    }

    @Test("the Karamazov fixture builds the outline the UI shows")
    func karamazovFixtureOutline() throws {
        let path = repoRoot
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("dostoyevsky_the_karamazov_brothers.epub")
            .path
        let info = try EpubParser.parse(path: path)
        let outline = ContentsOutline.build(from: info.chapters)

        // 001 (cover) and 002 (Gutenberg's title page, whose NCX carries
        // several entries) are two rows, not two plus the page's sub-entries.
        #expect(outline.front.count == 2)
        #expect(outline.front.first?.chapter.matter == .cover)
        #expect(outline.front.last?.chapter.key == "002")
        #expect(outline.front.last?.title == "The Brothers Karamazov")
        #expect(outline.front.allSatisfy { $0.kind == .matter })
        #expect(outline.back.map(\.title) == ["FOOTNOTES"])

        // Parts and books are unnumbered headings above the chapters.
        #expect(
            outline.body.contains {
                $0.title == "PART I" && $0.kind == .heading(level: 0)
            }
        )
        #expect(
            outline.body.contains {
                $0.title == "Book I. The History Of A Family" && $0.kind == .heading(level: 1)
            }
        )
        #expect(
            outline.body.contains {
                $0.title == "Book II. An Unfortunate Gathering" && $0.kind == .heading(level: 1)
            }
        )

        // Every one of the NCX's 96 chapter labels is a numbered leaf, and
        // none of the Gutenberg boilerplate leaked in.
        let chapterRows = outline.numberedChapters.filter { $0.title.hasPrefix("Chapter ") }
        #expect(chapterRows.count == 96)
        #expect(outline.numberedChapters.first?.title.hasPrefix("Chapter ") == true)
        #expect(
            !outline.body.contains { $0.title.hasPrefix("The Project Gutenberg eBook") }
        )
        // Numbering starts at 1 and is contiguous across parts and books.
        let numbers = outline.numberedChapters.compactMap { row -> Int? in
            if case let .chapter(number) = row.kind { return number }
            return nil
        }
        #expect(numbers == Array(1...numbers.count))
    }

    @Test("rows carry stable ids and section anchors")
    func rowIdentityAndAnchors() {
        let outline = ContentsOutline.build(from: [
            chapter(key: "009", title: "Book II", sections: [
                ChapterSection(title: "Book II", fragment: "book2", level: 1),
                ChapterSection(title: "Chapter I", fragment: "ch1", level: 2),
            ]),
        ])
        #expect(outline.body.map(\.id) == ["009#0", "009#1"])
        #expect(outline.body.map(\.jumpFragment) == ["book2", "ch1"])
        // Both rows share one chapter key: one note file, two anchors.
        #expect(Set(outline.body.map(\.chapter.key)) == ["009"])
    }
}
