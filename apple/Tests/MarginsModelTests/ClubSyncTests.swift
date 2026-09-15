import Foundation
import MarginsCore
@testable import MarginsModel
import Testing

/// Two accounts, one shared world: the in-memory stand-in for CloudKit that
/// phase 3's exit criteria can't exercise without real iCloud accounts.
/// `ClubSync`'s join/publish/rotate/remove logic runs against it unchanged.
actor ClubSyncWorld {
    private var clubs: [String: Club] = [:]
    private var snapshotsByClub: [String: [String: ClubMemberNotes]] = [:]
    private var shareURLs: [String: URL] = [:]
    private var invites: [String: ClubInvite] = [:]

    func put(_ club: Club) { clubs[club.id] = club }
    func club(_ id: String) -> Club? { clubs[id] }
    func put(_ snapshot: ClubMemberNotes, clubId: String) {
        snapshotsByClub[clubId, default: [:]][snapshot.memberId] = snapshot
    }
    func snapshots(clubId: String) -> [ClubMemberNotes] {
        (snapshotsByClub[clubId] ?? [:]).values.sorted { $0.memberId < $1.memberId }
    }
    func deleteSnapshot(clubId: String, memberId: String) {
        snapshotsByClub[clubId]?[memberId] = nil
    }
    func setShareURL(_ url: URL, clubId: String) { shareURLs[clubId] = url }
    func shareURL(clubId: String) -> URL? { shareURLs[clubId] }
    func put(_ invite: ClubInvite) { invites[invite.code] = invite }
    func invite(_ code: String) -> ClubInvite? { invites[code] }
    func deleteInvite(_ code: String) { invites[code] = nil }
    func deleteClub(id: String) {
        clubs[id] = nil
        snapshotsByClub[id] = nil
        shareURLs[id] = nil
        invites = invites.filter { $0.value.clubId != id }
    }
}

struct InMemoryClubSyncEngine: ClubSyncEngine {
    let world: ClubSyncWorld
    let memberId: String
    /// Simulates a transport that cannot create shares (CloudKit
    /// production schema missing, service down).
    var failsShare = false
    var shareFailure: ClubSyncError = .transport(
        "Cannot create new type cloudkit.share in production schema"
    )

    var supportsSharing: Bool { true }

    func currentMemberId() async throws -> String { memberId }

    func createShare(for club: Club) async throws -> ClubShare {
        if failsShare {
            throw shareFailure
        }
        let url = await world.shareURL(clubId: club.id)
            ?? URL(string: "https://example.com/share/\(club.id)")!
        await world.setShareURL(url, clubId: club.id)
        await world.put(club)
        return ClubShare(clubId: club.id, url: url)
    }

    func shareURL(forClubId clubId: String) async throws -> URL? {
        await world.shareURL(clubId: clubId)
    }

    func acceptShare(url: URL) async throws -> Club {
        guard let club = await world.club(url.lastPathComponent) else {
            throw ClubSyncError.unknownCode
        }
        return club
    }

    func fetchClub(id: String) async throws -> Club? { await world.club(id) }
    func publishClub(_ club: Club) async throws { await world.put(club) }

    func publishSnapshot(_ snapshot: ClubMemberNotes, clubId: String) async throws {
        await world.put(snapshot, clubId: clubId)
    }

    func fetchSnapshots(clubId: String) async throws -> [ClubMemberNotes] {
        await world.snapshots(clubId: clubId)
    }

    func deleteSnapshot(clubId: String, memberId: String) async throws {
        await world.deleteSnapshot(clubId: clubId, memberId: memberId)
    }

    func deleteClub(id: String) async throws {
        await world.deleteClub(id: id)
    }

    func removeParticipant(clubId: String, memberId: String) async throws {}

    func publishInvite(_ invite: ClubInvite) async throws { await world.put(invite) }
    func lookupInvite(code: String) async throws -> ClubInvite? { await world.invite(code) }
    func revokeInvite(code: String) async throws { await world.deleteInvite(code) }
}

@Suite("Club sync")
struct ClubSyncTests {
    private struct Fixture {
        let world: ClubSyncWorld
        let storeA: CoreStore
        let storeB: CoreStore
        let alice: ClubSync
        let bob: ClubSync
        let bookA: BookMeta
        let bookB: BookMeta
        let club: Club
    }

    /// Two devices, same book imported on both, Alice's club joined by Bob.
    private func twoMemberFixture() async throws -> Fixture {
        let world = ClubSyncWorld()
        let storeA = try CoreStore(dataDir: try makeTempDataDir())
        let storeB = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let bookA = try await storeA.importEpub(atPath: fixture)
        let bookB = try await storeB.importEpub(atPath: fixture)
        #expect(bookA.id == bookB.id, "the fixture import must be content-identical")

        let alice = ClubSync(
            store: storeA, engine: InMemoryClubSyncEngine(world: world, memberId: "alice")
        )
        let bob = ClubSync(
            store: storeB, engine: InMemoryClubSyncEngine(world: world, memberId: "bob")
        )
        let (club, _) = try await alice.createClub(
            bookId: bookA.id, name: "Thursday Readers",
            memberId: "alice", displayName: "Alice"
        )
        let joined = try await bob.joinClub(
            code: club.inviteCode, memberId: "bob", displayName: "Bob"
        )
        return Fixture(
            world: world, storeA: storeA, storeB: storeB,
            alice: alice, bob: bob, bookA: bookA, bookB: bookB, club: joined
        )
    }

    @Test("a second member joins by code and both snapshots merge")
    func twoMemberLifecycle() async throws {
        let fixture = try await twoMemberFixture()
        #expect(fixture.club.members.map(\.id).sorted() == ["alice", "bob"])

        let chapter = try #require(fixture.bookA.chapters.first)
        _ = try await fixture.storeA.saveChapterNote(
            bookId: fixture.bookA.id,
            chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: "Alice's thought.", kind: nil
        )
        try await fixture.alice.publishOwnSnapshot(
            clubId: fixture.club.id, memberId: "alice", displayName: "Alice"
        )

        _ = try await fixture.storeB.saveChapterNote(
            bookId: fixture.bookB.id,
            chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: "Bob's counterpoint.", kind: nil
        )
        try await fixture.bob.publishOwnSnapshot(
            clubId: fixture.club.id, memberId: "bob", displayName: "Bob"
        )

        let merged = try await fixture.alice.syncClub(
            clubId: fixture.club.id, viewerId: "alice", spoilerEnabled: false
        )
        #expect(merged.members.count == 2)
        let bodies = merged.chapters[0].contributions.map(\.body)
        #expect(bodies.contains("Alice's thought."))
        #expect(bodies.contains("Bob's counterpoint."))
    }

    @Test("join resolves the invite and rejects bad or expired codes")
    func codeValidation() async throws {
        let fixture = try await twoMemberFixture()

        do {
            _ = try await fixture.bob.joinClub(
                code: "!!", memberId: "bob", displayName: "Bob"
            )
            Issue.record("expected an invalid-code error")
        } catch let error as ClubSyncError {
            #expect(error == .invalidCode)
        }

        let engine = InMemoryClubSyncEngine(world: fixture.world, memberId: "carol")
        try await engine.publishInvite(
            ClubInvite(
                code: "ZZZZ",
                clubId: fixture.club.id,
                clubName: fixture.club.name,
                bookId: fixture.bookA.id,
                bookTitle: fixture.club.bookTitle,
                shareURL: URL(string: "https://example.com/share/\(fixture.club.id)")!,
                expiresAt: Date().addingTimeInterval(-60)
            )
        )
        let carol = ClubSync(store: try CoreStore(dataDir: try makeTempDataDir()), engine: engine)
        do {
            _ = try await carol.joinClub(code: "ZZZZ", memberId: "carol", displayName: "Carol")
            Issue.record("expected an expired-code error")
        } catch let error as ClubSyncError {
            #expect(error == .expiredCode)
        }
    }

    @Test("joining without the club's book fails before the share is accepted")
    func joinRequiresBook() async throws {
        let world = ClubSyncWorld()
        let storeA = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let bookA = try await storeA.importEpub(atPath: fixture)
        let alice = ClubSync(
            store: storeA, engine: InMemoryClubSyncEngine(world: world, memberId: "alice")
        )
        let (club, _) = try await alice.createClub(
            bookId: bookA.id, name: "Readers", memberId: "alice", displayName: "Alice"
        )

        // Bob has not imported the book: the join must fail before the
        // share is accepted, leaving no half-joined club behind.
        let storeB = try CoreStore(dataDir: try makeTempDataDir())
        let bob = ClubSync(
            store: storeB, engine: InMemoryClubSyncEngine(world: world, memberId: "bob")
        )
        do {
            _ = try await bob.joinClub(
                code: club.inviteCode, memberId: "bob", displayName: "Bob"
            )
            Issue.record("expected a book-missing error")
        } catch let error as ClubSyncError {
            #expect(error == .bookMissing(bookA.title))
        }
        #expect(try await storeB.listClubs().isEmpty)
        #expect(try await world.club(club.id)?.members.count == 1)
    }

    @Test("a failed share rolls the local club back and simplifies the error")
    func failedShareRollsBack() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)
        let sync = ClubSync(
            store: store,
            engine: InMemoryClubSyncEngine(
                world: ClubSyncWorld(), memberId: "alice", failsShare: true
            )
        )

        do {
            _ = try await sync.createClub(
                bookId: book.id, name: "Doomed", memberId: "alice", displayName: "Alice"
            )
            Issue.record("expected a sharing-unavailable error")
        } catch let error as ClubSyncError {
            #expect(error == .sharingSchemaMissing)
            #expect(
                error.errorDescription
                    == "Book club sharing isn't set up in this app's iCloud database yet. The CloudKit sharing types still need to be deployed."
            )
        }
        #expect(try await store.listClubs().isEmpty)
    }

    @Test("a transient share failure keeps the generic retry message")
    func transientShareFailureSimplifies() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)
        let sync = ClubSync(
            store: store,
            engine: InMemoryClubSyncEngine(
                world: ClubSyncWorld(), memberId: "alice", failsShare: true,
                shareFailure: .transport("The network connection was lost.")
            )
        )

        do {
            _ = try await sync.createClub(
                bookId: book.id, name: "Doomed", memberId: "alice", displayName: "Alice"
            )
            Issue.record("expected a sharing-unavailable error")
        } catch let error as ClubSyncError {
            #expect(error == .sharingUnavailable)
            #expect(
                error.errorDescription
                    == "Book club sharing is unavailable right now. Try again later."
            )
        }
        #expect(try await store.listClubs().isEmpty)
    }

    @Test("rotation revokes the old code and indexes the new one")
    func rotation() async throws {
        let fixture = try await twoMemberFixture()
        let oldCode = fixture.club.inviteCode
        let newCode = try await fixture.alice.rotateInviteCode(clubId: fixture.club.id)

        #expect(newCode != oldCode)
        #expect(try await fixture.world.invite(oldCode) == nil)
        #expect(try await fixture.world.invite(newCode) != nil)
        #expect(try await fixture.world.club(fixture.club.id)?.inviteCode == newCode)
    }

    @Test("removing a member drops the roster entry and the snapshot")
    func removeMember() async throws {
        let fixture = try await twoMemberFixture()
        let chapter = try #require(fixture.bookB.chapters.first)
        _ = try await fixture.storeB.saveChapterNote(
            bookId: fixture.bookB.id,
            chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: "Bob's note.", kind: nil
        )
        try await fixture.bob.publishOwnSnapshot(
            clubId: fixture.club.id, memberId: "bob", displayName: "Bob"
        )

        let updated = try await fixture.alice.removeMember(
            clubId: fixture.club.id, memberId: "bob"
        )
        #expect(updated.members.map(\.id) == ["alice"])
        #expect(try await fixture.world.snapshots(clubId: fixture.club.id).isEmpty)
        #expect(
            try await fixture.storeA.clubMemberSnapshots(clubId: fixture.club.id).isEmpty
        )
    }

    @Test("the current member id comes from the transport")
    func currentMemberId() async throws {
        let fixture = try await twoMemberFixture()
        #expect(try await fixture.alice.currentMemberId() == "alice")
        #expect(try await fixture.bob.currentMemberId() == "bob")
    }

    @Test("automatic picks the local engine in a process without iCloud entitlements")
    func automaticFallsBackWithoutEntitlement() async throws {
        // This test process is unsigned, the same state as the ad-hoc
        // `make app` bundle. The ubiquity token is non-nil even there on
        // macOS, so the fallback must key off the entitlement — without it,
        // constructing CKContainer traps before a window ever appears.
        #expect(!ClubSync.cloudKitIsUsable())

        let store = try CoreStore(dataDir: try makeTempDataDir())
        let sync = await ClubSync.automatic(store: store)
        #expect(!sync.supportsSharing)
    }

    @Test("the local engine gives an unsigned build working single-member clubs")
    func localEngine() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)
        let identity = try await store.clubIdentity()
        let sync = ClubSync(
            store: store,
            engine: LocalClubSyncEngine(store: store, memberId: identity.memberId)
        )
        #expect(!sync.supportsSharing)

        let result = try await sync.createClub(
            bookId: book.id, name: "Solo", memberId: identity.memberId,
            displayName: "Solo Reader"
        )
        #expect(result.shareURL.scheme == "margins-local")

        let chapter = try #require(book.chapters.first)
        _ = try await store.saveChapterNote(
            bookId: book.id, chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: "Alone with a book.", kind: nil
        )
        try await sync.publishOwnSnapshot(
            clubId: result.club.id, memberId: identity.memberId, displayName: "Solo Reader"
        )
        let notes = try await sync.syncClub(
            clubId: result.club.id, viewerId: identity.memberId, spoilerEnabled: false
        )
        #expect(notes.chapters[0].contributions.first?.body == "Alone with a book.")
    }
}
