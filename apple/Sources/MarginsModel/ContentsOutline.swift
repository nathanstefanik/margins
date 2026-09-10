import Foundation
import MarginsCore

/// One row of the shared chapter outline: a book's front matter, a body
/// heading, a numbered body chapter, or a back-matter file. The macOS detail
/// list, the iOS contents list, and the iOS reader's contents sheet all render
/// this one shape, built from `ChapterMeta.sections` by `ContentsOutline`.
public struct OutlineRow: Identifiable, Equatable, Sendable {
    /// What a body row is. Front/back rows are always `.matter`.
    public enum Kind: Equatable, Sendable {
        /// A part/book/volume container; `level` is its outline depth.
        case heading(level: Int)
        /// A leaf chapter, numbered from 1 across the body in reading order.
        case chapter(number: Int)
        /// A front- or back-matter file.
        case matter
    }

    /// Stable across rebuilds: the chapter key plus the section's index.
    public let id: String
    public let chapter: ChapterMeta
    /// The TOC entry this row shows; `nil` when the chapter has no TOC entry
    /// and the row falls back to the chapter's own title.
    public let section: ChapterSection?
    public let title: String
    public let kind: Kind

    /// Anchor to jump to for this row: the section's fragment, else the
    /// chapter's first-section fragment (the top of the file when neither
    /// names one). Nil means the top of `chapter.href`.
    public var jumpFragment: String? { section?.fragment ?? chapter.fragment }

    public init(
        id: String,
        chapter: ChapterMeta,
        section: ChapterSection?,
        title: String,
        kind: Kind
    ) {
        self.id = id
        self.chapter = chapter
        self.section = section
        self.title = title
        self.kind = kind
    }
}

/// A book's structure split for an outline UI: front matter grouped under
/// cover, the reading body, and the back matter. Built once from
/// `BookMeta.chapters`; pure so the views and tests share one definition.
public struct ContentsOutline: Equatable, Sendable {
    /// Cover and front matter, spine order.
    public let front: [OutlineRow]
    /// Body headings and numbered chapters, reading order.
    public let body: [OutlineRow]
    /// Back matter, spine order.
    public let back: [OutlineRow]

    public init(front: [OutlineRow], body: [OutlineRow], back: [OutlineRow]) {
        self.front = front
        self.body = body
        self.back = back
    }

    /// Body rows that are leaf chapters, in reading order.
    public var numberedChapters: [OutlineRow] {
        body.filter {
            if case .chapter = $0.kind { return true }
            return false
        }
    }

    /// The count a detail header shows as "N chapters": numbered leaf rows,
    /// never the raw spine count (front/back matter and headings excluded).
    public var numberedChapterCount: Int { numberedChapters.count }

    public static func build(from chapters: [ChapterMeta]) -> ContentsOutline {
        var front: [OutlineRow] = []
        var body: [OutlineRow] = []
        var back: [OutlineRow] = []
        for chapter in chapters {
            switch chapter.matter {
            case .cover, .front:
                front.append(contentsOf: rows(for: chapter, kind: .matter))
            case .back:
                back.append(contentsOf: rows(for: chapter, kind: .matter))
            case .body:
                body.append(contentsOf: rows(for: chapter, kind: nil))
            }
        }
        return ContentsOutline(front: front, body: number(body), back: back)
    }

    /// Expands one chapter into a row per TOC entry. A chapter the TOC never
    /// names becomes a single row carrying its own title.
    private static func rows(for chapter: ChapterMeta, kind: OutlineRow.Kind?) -> [OutlineRow] {
        let sections = chapter.sections
        if sections.isEmpty {
            return [
                OutlineRow(
                    id: "\(chapter.key)#0",
                    chapter: chapter,
                    section: nil,
                    title: chapter.title,
                    kind: kind ?? .chapter(number: 0)
                )
            ]
        }
        return sections.enumerated().map { index, section in
            OutlineRow(
                id: "\(chapter.key)#\(index)",
                chapter: chapter,
                section: section,
                title: section.title,
                kind: kind ?? .chapter(number: 0)
            )
        }
    }

    /// Classifies and numbers the body rows. A row is a heading when a later
    /// section of the same chapter is deeper, or the next body row is deeper;
    /// leaves are chapters numbered from 1 across the whole body in reading
    /// order, sharing one number sequence across parts and books. If no row
    /// qualifies as a leaf the level data is degenerate and every body row
    /// is numbered so the outline stays navigable.
    private static func number(_ body: [OutlineRow]) -> [OutlineRow] {
        guard !body.isEmpty else { return body }

        func level(_ row: OutlineRow) -> Int {
            if case let .heading(level) = row.kind { return level }
            return row.section?.level ?? row.chapter.level
        }

        var isHeading = Array(repeating: false, count: body.count)
        for i in body.indices {
            let current = level(body[i])
            var j = i + 1
            while j < body.count, body[j].chapter.key == body[i].chapter.key {
                if level(body[j]) > current {
                    isHeading[i] = true
                    break
                }
                j += 1
            }
            if !isHeading[i], i + 1 < body.count, level(body[i + 1]) > current {
                isHeading[i] = true
            }
        }

        var numbered: [OutlineRow] = []
        numbered.reserveCapacity(body.count)
        var nextNumber = 0
        for (i, row) in body.enumerated() {
            if isHeading[i] {
                numbered.append(
                    OutlineRow(
                        id: row.id,
                        chapter: row.chapter,
                        section: row.section,
                        title: row.title,
                        kind: .heading(level: level(row))
                    )
                )
            } else {
                nextNumber += 1
                numbered.append(
                    OutlineRow(
                        id: row.id,
                        chapter: row.chapter,
                        section: row.section,
                        title: row.title,
                        kind: .chapter(number: nextNumber)
                    )
                )
            }
        }

        guard nextNumber == 0 else { return numbered }
        return body.enumerated().map { index, row in
            OutlineRow(
                id: row.id,
                chapter: row.chapter,
                section: row.section,
                title: row.title,
                kind: .chapter(number: index + 1)
            )
        }
    }
}
