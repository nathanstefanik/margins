import Foundation
import MarginsCore
import Testing

/// Phase 2 integration: the club surface as the apps drive it — create a
/// club from an imported book, turn local notes into a snapshot, merge in a
/// second member's snapshot, and watch spoiler protection follow the reading
/// position.
@Suite("Club store bridge")
struct ClubStoreBridgeTests {
    @Test("create, snapshot, merge, and spoiler through the store")
    func fullFlow() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)
        let first = try #require(book.chapters.first)
        let second = try #require(book.chapters.dropFirst().first)

        let club = try await store.createClub(
            bookId: book.id, name: "Thursday Readers",
            adminId: "alice", adminName: "Alice"
        )
        #expect(club.members.count == 1)
        #expect(club.bookTitle == book.title)

        // Alice's local notes become her snapshot.
        _ = try await store.saveChapterNote(
            bookId: book.id, chapter: ChapterRef(key: first.key, epubCfi: nil),
            body: "Alice on one.", kind: nil
        )
        _ = try await store.saveChapterNote(
            bookId: book.id, chapter: ChapterRef(key: second.key, epubCfi: nil),
            body: "Alice on two.", kind: nil
        )
        let alice = try await store.buildClubMemberSnapshot(
            clubId: club.id, memberId: "alice", displayName: "Alice"
        )
        #expect(alice.chapters.map(\.chapterKey) == [first.key, second.key])
        try await store.saveClubMemberSnapshot(clubId: club.id, snapshot: alice)

        // Bob is another device: he is on the roster and his snapshot
        // arrives with different content.
        var roster = club
        roster.members.append(
            ClubMember(id: "bob", displayName: "Bob", role: .member, joinedAt: Date())
        )
        try await store.updateClub(roster)

        let bob = ClubMemberNotes(
            memberId: "bob", displayName: "Bob", bookId: book.id,
            bookTitle: book.title, bookAuthor: book.author,
            chapterCount: book.chapters.count, updatedAt: Date(),
            chapters: [
                CompiledChapter(
                    chapterKey: first.key, chapterIndex: first.index,
                    chapterTitle: first.title, body: "Bob on one.", wordCount: 3
                ),
                CompiledChapter(
                    chapterKey: second.key, chapterIndex: second.index,
                    chapterTitle: second.title, body: "Bob on two.", wordCount: 3
                ),
            ]
        )
        try await store.saveClubMemberSnapshot(clubId: club.id, snapshot: bob)
        #expect(try await store.clubMemberSnapshots(clubId: club.id).count == 2)

        // No reading position yet: default protection hides Bob entirely.
        let hidden = try await store.clubNotes(clubId: club.id, viewerId: "alice")
        #expect(hidden.spoilerProtected)
        #expect(hidden.chapters[0].contributions.map(\.displayName) == ["Alice"])
        #expect(hidden.chapters[0].hiddenMemberCount == 1)

        // Reading chapter one unlocks everyone's notes through chapter one.
        try await store.saveReadingPosition(
            bookId: book.id,
            position: ReadingPosition(chapterKey: second.key, percent: 10)
        )
        let reading = try await store.clubNotes(clubId: club.id, viewerId: "alice")
        #expect(reading.chapters[0].contributions.map(\.displayName) == ["Alice", "Bob"])
        #expect(reading.chapters[1].contributions.map(\.displayName) == ["Alice"])
        #expect(reading.chapters[1].hiddenMemberCount == 1)

        // The merged export carries visible content and a placeholder only.
        let export = try await store.renderClubNotesMarkdown(clubId: club.id, viewerId: "alice")
        #expect(export.contains("Bob on one."))
        #expect(!export.contains("Bob on two."))
        #expect(export.contains("hidden until you finish this chapter"))

        // Turning protection off reveals the rest.
        let revealed = try await store.clubNotes(
            clubId: club.id, viewerId: "alice", spoilerEnabled: false
        )
        #expect(revealed.chapters[1].contributions.map(\.displayName) == ["Alice", "Bob"])
    }

    @Test("clubs list, rotate, and delete through the store")
    func clubLifecycle() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)

        let club = try await store.createClub(
            bookId: book.id, name: "Solitude", adminId: "alice", adminName: "Alice"
        )
        #expect(try await store.listClubs().map(\.id) == [club.id])

        let code = try await store.rotateClubInviteCode(clubId: club.id)
        #expect(code != club.inviteCode)
        #expect(try await store.getClub(id: club.id).inviteCode == code)

        try await store.deleteClub(id: club.id)
        #expect(try await store.listClubs().isEmpty)
    }

    @Test("a club for a missing book is rejected")
    func missingBookRejected() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        do {
            _ = try await store.createClub(
                bookId: "not-a-book", name: "Ghost", adminId: "alice", adminName: "Alice"
            )
            Issue.record("expected createClub to throw for a missing book")
        } catch let error as CoreError {
            #expect(error.message.contains("book not found"))
        }
    }

    @Test("the spoiler toggle persists through the store")
    func spoilerTogglePersists() async throws {
        let dataDir = try makeTempDataDir()
        let store = try CoreStore(dataDir: dataDir)
        #expect(try await store.clubSpoilerProtection())

        try await store.setClubSpoilerProtection(false)
        #expect(!(try await store.clubSpoilerProtection()))

        let reloaded = try CoreStore(dataDir: dataDir)
        #expect(!(try await reloaded.clubSpoilerProtection()))
    }

    @Test("adopting a transport member id migrates local clubs and snapshots")
    func adoptMemberIdMigratesClubs() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)
        let identity = try await store.clubIdentity()
        let club = try await store.createClub(
            bookId: book.id, name: "Solo", adminId: identity.memberId, adminName: "Alice"
        )
        try await store.saveClubMemberSnapshot(
            clubId: club.id,
            snapshot: ClubMemberNotes(
                memberId: identity.memberId, displayName: "Alice", bookId: book.id,
                bookTitle: book.title, bookAuthor: book.author,
                chapterCount: book.chapters.count, updatedAt: Date(), chapters: []
            )
        )

        try await store.adoptClubMemberId("_cloud-user")

        #expect(try await store.clubIdentity().memberId == "_cloud-user")
        #expect(try await store.getClub(id: club.id).members.map(\.id) == ["_cloud-user"])
        let migrated = try await store.clubMemberSnapshots(clubId: club.id)
        #expect(migrated.count == 1)
        #expect(migrated.first?.memberId == "_cloud-user")

        // Re-adopting the same id changes nothing.
        try await store.adoptClubMemberId("_cloud-user")
        #expect(try await store.clubMemberSnapshots(clubId: club.id).count == 1)
    }
}
