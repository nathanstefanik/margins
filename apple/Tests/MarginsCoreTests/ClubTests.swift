import Foundation
@testable import MarginsCore
import Testing

@Suite("Club")
struct ClubTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func member(
        _ id: String, _ name: String, role: ClubRole = .member, joined: TimeInterval = 0
    ) -> ClubMember {
        ClubMember(
            id: id, displayName: name, role: role,
            joinedAt: epoch.addingTimeInterval(joined)
        )
    }

    private func club(members: [ClubMember]) -> Club {
        Club(
            id: "b01j8q3k2m",
            name: "Thursday Readers",
            bookId: "a1b2c3d4e5f6",
            bookTitle: "Middlemarch",
            bookAuthor: "George Eliot",
            inviteCode: "7KQP",
            createdAt: epoch,
            members: members
        )
    }

    // MARK: Codes

    @Test("generated codes are four Crockford characters")
    func generatedCodeShape() {
        for _ in 0..<32 {
            let code = ClubCode.generate()
            #expect(code.count == ClubCode.length)
            #expect(code.allSatisfy { ClubCode.alphabet.contains($0) })
            #expect(ClubCode.isValid(code))
        }
    }

    @Test("codes normalize aliases, case, and spacing")
    func codeNormalization() {
        #expect(ClubCode.normalize("7kqp") == "7KQP")
        #expect(ClubCode.normalize(" o1i l ") == "0111")
        #expect(ClubCode.normalize("AB-CD") == "ABCD")
        #expect(ClubCode.normalize("ABC") == nil)
        #expect(ClubCode.normalize("ABCDE") == nil)
        #expect(ClubCode.normalize("AB!D") == nil)
        #expect(ClubCode.normalize("UUUU") == nil)
    }

    // MARK: Roster

    @Test("the roster puts the admin first, then join order")
    func rosterOrder() {
        let club = club(members: [
            member("c", "Carol", joined: 20),
            member("a", "Alice", role: .admin, joined: 10),
            member("b", "Bob", joined: 5),
        ])
        #expect(club.roster.map(\.displayName) == ["Alice", "Bob", "Carol"])
        #expect(club.isAdmin("a"))
        #expect(!club.isAdmin("b"))
        #expect(club.admin?.id == "a")
        #expect(club.member(id: "b")?.displayName == "Bob")
        #expect(club.member(id: "zzz") == nil)
    }

    // MARK: Codable

    @Test("a club survives a JSON round-trip with snake_case keys")
    func clubRoundTrips() throws {
        let club = club(members: [
            member("a", "Alice", role: .admin),
            member("b", "Bob", joined: 5),
        ])
        let data = try MarginsJSON.encode(club)
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains("\"book_id\""))
        #expect(raw.contains("\"invite_code\""))
        #expect(raw.contains("\"joined_at\""))
        #expect(try MarginsJSON.decode(Club.self, from: data) == club)
    }

    @Test("a member snapshot survives a JSON round-trip")
    func memberNotesRoundTrip() throws {
        let snapshot = ClubMemberNotes(
            memberId: "a",
            displayName: "Alice",
            bookId: "a1b2c3",
            bookTitle: "Middlemarch",
            bookAuthor: "George Eliot",
            chapterCount: 86,
            updatedAt: epoch,
            chapters: [
                CompiledChapter(
                    chapterKey: "001", chapterIndex: 0, chapterTitle: "Prelude",
                    body: "A body.", marks: [], wordCount: 2, updatedAt: epoch
                )
            ]
        )
        let data = try MarginsJSON.encode(snapshot)
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains("\"member_id\""))
        #expect(raw.contains("\"chapter_count\""))
        #expect(try MarginsJSON.decode(ClubMemberNotes.self, from: data) == snapshot)
    }

    // MARK: Snapshots

    @Test("a snapshot carries only chapters with content")
    func snapshotKeepsOnlyContentChapters() {
        let quoteMark = Mark(
            id: "b01j8q3k2m", cfi: "epubcfi(/6/4!/4/2/1:0)", at: epoch,
            percent: 12, quote: "quoted", body: "thought"
        )
        let compiled = CompiledNotes(
            bookId: "a1b2c3",
            bookTitle: "Middlemarch",
            bookAuthor: "George Eliot",
            chapters: [
                CompiledChapter(
                    chapterKey: "001", chapterIndex: 0, chapterTitle: "One",
                    body: "A body.", wordCount: 2, updatedAt: epoch
                ),
                CompiledChapter(
                    chapterKey: "002", chapterIndex: 1, chapterTitle: "Two",
                    body: "", marks: [], wordCount: 0
                ),
                CompiledChapter(
                    chapterKey: "003", chapterIndex: 2, chapterTitle: "Three",
                    body: "", marks: [quoteMark], wordCount: 0, updatedAt: epoch
                ),
            ],
            emptyChapters: [],
            chaptersWithNotes: 2,
            chapterCount: 10,
            totalWords: 2,
            lastUpdatedAt: epoch,
            suggestedFilename: "x.md"
        )

        let snapshot = ClubCompile.snapshot(
            compiled, memberId: "a", displayName: "Alice"
        )
        #expect(snapshot.chapters.map(\.chapterKey) == ["001", "003"])
        #expect(snapshot.chapterCount == 10)
        #expect(snapshot.updatedAt == epoch)
        #expect(snapshot.bookTitle == "Middlemarch")
    }

    @Test("spoiler protection defaults on and can be turned off")
    func spoilerPolicyDefaults() {
        #expect(SpoilerPolicy.default.isEnabled)
        #expect(!SpoilerPolicy.off.isEnabled)
    }
}
