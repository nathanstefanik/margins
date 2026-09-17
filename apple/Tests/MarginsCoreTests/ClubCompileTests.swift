import Foundation
@testable import MarginsCore
import Testing

/// The merged-view contract: snapshots in, one document out, with spoiler
/// gating and passage clustering applied. Pure, so everything runs without
/// iCloud or a library on disk.
@Suite("ClubCompile")
struct ClubCompileTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Harness

    private func member(_ id: String, _ name: String, _ role: ClubRole = .member) -> ClubMember {
        ClubMember(id: id, displayName: name, role: role, joinedAt: epoch)
    }

    private func club(_ members: [ClubMember]) -> Club {
        Club(
            id: "club1",
            name: "Thursday Readers",
            bookId: "book1",
            bookTitle: "Middlemarch",
            bookAuthor: "George Eliot",
            inviteCode: "7KQP",
            createdAt: epoch,
            ownerMemberId: members.first(where: \.isAdmin)?.id ?? members.first?.id ?? "owner",
            members: members
        )
    }

    private func mark(
        _ id: String, cfi: String? = nil, percent: Double? = nil,
        quote: String = "", body: String = ""
    ) -> Mark {
        Mark(id: id, cfi: cfi, at: epoch, percent: percent, quote: quote, body: body)
    }

    private func chapter(
        _ key: String, index: Int, title: String? = nil,
        body: String = "", marks: [Mark] = []
    ) -> CompiledChapter {
        CompiledChapter(
            chapterKey: key, chapterIndex: index,
            chapterTitle: title ?? "Chapter \(index + 1)",
            body: body, marks: marks,
            wordCount: Notes.countWords(body), updatedAt: epoch
        )
    }

    private func snapshot(
        _ id: String, _ name: String, _ chapters: [CompiledChapter]
    ) -> ClubMemberNotes {
        ClubMemberNotes(
            memberId: id, displayName: name, bookId: "book1",
            bookTitle: "Middlemarch", bookAuthor: "George Eliot",
            chapterCount: 10, updatedAt: epoch, chapters: chapters
        )
    }

    // MARK: Merging

    @Test("two members' chapter notes merge into one chapter")
    func mergesContributions() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [chapter("001", index: 0, body: "Alice thinks this.")]),
                snapshot("bob", "Bob", [chapter("001", index: 0, body: "Bob disagrees.")]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        #expect(notes.chapters.count == 1)
        #expect(notes.chapters[0].contributions.map(\.displayName) == ["Alice", "Bob"])
        #expect(notes.chapters[0].passages.isEmpty)
        #expect(notes.totalWords == 5)
    }

    @Test("snapshots from members off the roster are ignored")
    func removedMemberIgnored() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin)]),
            snapshots: [
                snapshot("alice", "Alice", [chapter("001", index: 0, body: "Alice.")]),
                snapshot("mallory", "Mallory", [chapter("001", index: 0, body: "Mallory.")]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        #expect(notes.chapters[0].contributions.map(\.displayName) == ["Alice"])
        #expect(notes.totalWords == 1)
    }

    // MARK: Spoiler protection

    @Test("spoiler protection hides others from the viewer's chapter onward")
    func spoilerGating() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [
                    chapter("001", index: 0, body: "Alice one."),
                    chapter("002", index: 1, body: "Alice two."),
                ]),
                snapshot("bob", "Bob", [
                    chapter("001", index: 0, body: "Bob one."),
                    chapter("002", index: 1, body: "Bob two."),
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 1
        )

        let first = notes.chapters[0]
        #expect(first.contributions.map(\.displayName) == ["Alice", "Bob"])
        #expect(!first.othersHidden)

        let second = notes.chapters[1]
        #expect(second.contributions.map(\.displayName) == ["Alice"])
        #expect(second.othersHidden)
        #expect(second.hiddenMemberCount == 1)
        #expect(second.hiddenContributionCount == 1)
        #expect(second.hiddenMarkCount == 0)
        #expect(notes.totalWords == 6)
    }

    @Test("turning the policy off shows every member's notes")
    func spoilerOff() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [chapter("001", index: 0, body: "Alice.")]),
                snapshot("bob", "Bob", [chapter("001", index: 0, body: "Bob.")]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        #expect(notes.chapters[0].contributions.map(\.displayName) == ["Alice", "Bob"])
        #expect(!notes.chapters[0].othersHidden)
        #expect(!notes.spoilerProtected)
    }

    @Test("no reading position hides all other members' content")
    func noPositionHidesAll() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [chapter("001", index: 0, body: "Alice.")]),
                snapshot("bob", "Bob", [chapter("001", index: 0, body: "Bob.")]),
            ],
            viewerId: "alice",
            viewerChapterIndex: nil
        )

        #expect(notes.chapters[0].contributions.map(\.displayName) == ["Alice"])
        #expect(notes.chapters[0].hiddenMemberCount == 1)
        #expect(notes.totalWords == 1)
    }

    @Test("a chapter only another member annotated appears as a placeholder")
    func hiddenOnlyChapter() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [chapter("001", index: 0, body: "Alice first.")]),
                snapshot("bob", "Bob", [chapter("003", index: 2, body: "Bob secret.")]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0
        )

        #expect(notes.chapters.map(\.chapterKey) == ["001", "003"])
        let hidden = notes.chapters[1]
        #expect(hidden.othersHidden)
        #expect(!hidden.hasVisibleContent)
        #expect(hidden.hiddenContributionCount == 1)
        #expect(notes.totalWords == 2)
    }

    // MARK: Clustering

    @Test("overlapping marks cluster under one passage")
    func clusteringByCFI() {
        let notes = ClubCompile.compile(
            club: club([
                member("alice", "Alice", .admin),
                member("bob", "Bob"),
                member("carol", "Carol"),
            ]),
            snapshots: [
                snapshot("alice", "Alice", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "aaaaaaaaaa",
                            cfi: "epubcfi(/6/14!/4/2/10,/1:0,/1:42)",
                            percent: 10,
                            quote: "It is a truth universally acknowledged",
                            body: "Alice's thought"
                        )
                    ])
                ]),
                snapshot("bob", "Bob", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "bbbbbbbbbb",
                            cfi: "epubcfi(/6/14!/4/2/10,/1:10,/1:50)",
                            percent: 10.2,
                            quote: "truth universally acknowledged",
                            body: "Bob's thought"
                        )
                    ])
                ]),
                snapshot("carol", "Carol", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "cccccccccc",
                            cfi: "epubcfi(/6/14!/4/2/30,/1:0,/1:10)",
                            percent: 40,
                            quote: "Elsewhere",
                            body: "Carol's thought"
                        )
                    ])
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        let passages = notes.chapters[0].passages
        #expect(passages.count == 2)
        #expect(passages[0].marks.map(\.displayName) == ["Alice", "Bob"])
        #expect(passages[0].quote == "It is a truth universally acknowledged")
        #expect(passages[0].cfi == "epubcfi(/6/14!/4/2/10,/1:0,/1:42)")
        #expect(passages[0].percent == 10)
        #expect(passages[1].marks.map(\.displayName) == ["Carol"])
    }

    @Test("marks without CFIs cluster on an identical quote")
    func clusteringByQuote() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [
                    chapter("001", index: 0, marks: [
                        mark("aaaaaaaaaa", quote: "Same Passage", body: "A")
                    ])
                ]),
                snapshot("bob", "Bob", [
                    chapter("001", index: 0, marks: [
                        mark("bbbbbbbbbb", quote: "  same   passage ", body: "B")
                    ])
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        #expect(notes.chapters[0].passages.count == 1)
        #expect(notes.chapters[0].passages[0].marks.count == 2)
    }

    @Test("non-overlapping marks stay separate passages")
    func nonOverlappingMarks() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "aaaaaaaaaa",
                            cfi: "epubcfi(/6/14!/4/2/10,/1:0,/1:5)",
                            quote: "First fragment"
                        )
                    ])
                ]),
                snapshot("bob", "Bob", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "bbbbbbbbbb",
                            cfi: "epubcfi(/6/14!/4/2/10,/1:10,/1:20)",
                            quote: "Second fragment"
                        )
                    ])
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        #expect(notes.chapters[0].passages.count == 2)
    }

    @Test("disjoint CFI ranges keep identical quotes apart")
    func disjointCFIsStaySeparate() {
        // Both CFIs parse and point at different paragraphs: the quote
        // fallback must not merge them just because the text matches.
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "aaaaaaaaaa",
                            cfi: "epubcfi(/6/14!/4/2/10,/1:0,/1:5)",
                            quote: "Yes",
                            body: "A"
                        )
                    ])
                ]),
                snapshot("bob", "Bob", [
                    chapter("001", index: 0, marks: [
                        mark(
                            "bbbbbbbbbb",
                            cfi: "epubcfi(/6/14!/4/2/30,/1:0,/1:5)",
                            quote: "Yes",
                            body: "B"
                        )
                    ])
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0,
            spoilerPolicy: .off
        )

        #expect(notes.chapters[0].passages.count == 2)
    }

    @Test("hidden marks are counted, never rendered")
    func hiddenMarksCounted() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [chapter("001", index: 0, body: "Alice.")]),
                snapshot("bob", "Bob", [
                    chapter("001", index: 0, marks: [
                        mark("bbbbbbbbbb", quote: "Bob secret one"),
                        mark("cccccccccc", quote: "Bob secret two"),
                    ])
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 0
        )

        let chapter = notes.chapters[0]
        #expect(chapter.othersHidden)
        #expect(chapter.hiddenMarkCount == 2)
        #expect(chapter.hiddenContributionCount == 0)
        #expect(chapter.passages.isEmpty)
    }

    // MARK: Markdown

    private func markdownClub() -> ClubNotes {
        ClubCompile.compile(
            club: club([member("alice", "Alice", .admin), member("bob", "Bob")]),
            snapshots: [
                snapshot("alice", "Alice", [
                    chapter(
                        "001", index: 0, body: "Alice long-form body.",
                        marks: [
                            mark(
                                "aaaaaaaaaa",
                                cfi: "epubcfi(/6/14!/4/2/10,/1:0,/1:42)",
                                percent: 10,
                                quote: "It is a truth",
                                body: "Alice's thought"
                            )
                        ]
                    )
                ]),
                snapshot("bob", "Bob", [
                    chapter(
                        "001", index: 0, body: "Bob long-form body.",
                        marks: [
                            mark(
                                "bbbbbbbbbb",
                                cfi: "epubcfi(/6/14!/4/2/10,/1:10,/1:50)",
                                percent: 10,
                                quote: "truth",
                                body: ""
                            )
                        ]
                    ),
                    chapter("002", index: 1, body: "Bob hidden body."),
                ]),
            ],
            viewerId: "alice",
            viewerChapterIndex: 1
        )
    }

    @Test("the merged export renders passages, notes, and the spoiler line")
    func markdownShape() {
        let markdown = ClubCompile.renderMarkdown(markdownClub())

        #expect(markdown.hasPrefix("# Club Notes — Thursday Readers\n"))
        #expect(markdown.contains("*Middlemarch — George Eliot*"))
        #expect(markdown.contains("2 members"))
        #expect(markdown.contains("Spoiler protection is on"))
        #expect(markdown.contains("### Passages"))
        #expect(markdown.contains("> It is a truth"))
        #expect(markdown.contains("**Alice:**\nAlice's thought"))
        #expect(markdown.contains("**Bob:**\n*(highlight)*"))
        #expect(markdown.contains("### Notes"))
        #expect(markdown.contains("**Alice**\n\nAlice long-form body."))
        #expect(
            markdown.contains(
                "_1 other member's notes are hidden until you finish this chapter._"
            )
        )
        #expect(!markdown.contains("Bob hidden body."))
    }

    @Test("the meeting brief drops long-form notes")
    func meetingBrief() {
        let markdown = ClubCompile.renderMarkdown(
            markdownClub(), options: .meetingBrief
        )
        #expect(markdown.contains("### Passages"))
        #expect(!markdown.contains("### Notes"))
        #expect(!markdown.contains("Alice long-form body."))
    }

    @Test("a club with no snapshots renders an empty document")
    func emptyClub() {
        let notes = ClubCompile.compile(
            club: club([member("alice", "Alice", .admin)]),
            snapshots: [],
            viewerId: "alice",
            viewerChapterIndex: nil
        )
        let markdown = ClubCompile.renderMarkdown(notes)
        #expect(markdown.contains("_No notes yet._"))
        #expect(notes.chapters.isEmpty)
        #expect(notes.chapterCount == 0)
    }

    @Test("the suggested filename strips path-hostile characters")
    func filenameSanitized() {
        #expect(
            ClubCompile.suggestedExportFilename(
                clubName: "Book/Club: Q3", bookTitle: "Middle/march"
            ) == "Book Club Q3 — Middle march — club notes.md"
        )
        #expect(
            ClubCompile.suggestedExportFilename(clubName: "", bookTitle: "")
                == "Book Club — Notes — club notes.md"
        )
    }
}
