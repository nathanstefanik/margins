import Foundation
@testable import MarginsCore
import Testing

/// The local club store is the documented on-disk layout:
/// `{root}/{club_id}/club.json` + `{root}/{club_id}/members/{member_id}.json`.
/// Everything here runs against a temporary root.
@Suite("Club store")
struct ClubStoreTests {
    private func temporaryRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-clubs-\(UUID().uuidString)", isDirectory: true)
            .path
        return root
    }

    private func snapshot(_ id: String, _ name: String) -> ClubMemberNotes {
        ClubMemberNotes(
            memberId: id,
            displayName: name,
            bookId: "book1",
            bookTitle: "Middlemarch",
            bookAuthor: "George Eliot",
            chapterCount: 10,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            chapters: []
        )
    }

    private func create(_ store: ClubStore, admin: String = "alice") throws -> Club {
        try store.createClub(
            name: "Thursday Readers",
            bookId: "book1",
            bookTitle: "Middlemarch",
            bookAuthor: "George Eliot",
            adminId: admin,
            adminName: admin.capitalized
        )
    }

    @Test("creating a club writes the documented layout")
    func createsLayout() throws {
        let store = ClubStore(root: try temporaryRoot())
        let club = try create(store)

        #expect(club.id.count == 10)
        #expect(ClubCode.isValid(club.inviteCode))
        #expect(club.admin?.id == "alice")
        #expect(club.members.count == 1)
        #expect(club.bookTitle == "Middlemarch")

        let directory = store.clubDir(club.id)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("club.json")))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("members")))
    }

    @Test("clubs list and round-trip")
    func listAndGet() throws {
        let store = ClubStore(root: try temporaryRoot())
        #expect(try store.listClubs().isEmpty)

        let first = try create(store)
        let second = try create(store, admin: "bob")
        let listed = try store.listClubs()
        #expect(Set(listed.map(\.id)) == Set([first.id, second.id]))
        #expect(try store.getClub(id: first.id) == first)
        #expect(try store.getClub(id: second.id) == second)
    }

    @Test("rotation always changes the code and persists it")
    func rotation() throws {
        let store = ClubStore(root: try temporaryRoot())
        let created = try create(store)
        let rotated = try store.rotateInviteCode(clubId: created.id)

        #expect(rotated.inviteCode != created.inviteCode)
        #expect(try store.getClub(id: created.id).inviteCode == rotated.inviteCode)
    }

    @Test("update persists roster changes; a missing club is not recreated")
    func updateRoster() throws {
        let store = ClubStore(root: try temporaryRoot())
        var club = try create(store)
        club.members.append(
            ClubMember(
                id: "bob", displayName: "Bob", role: .member,
                joinedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        )
        try store.updateClub(club)
        #expect(try store.getClub(id: club.id).members.count == 2)

        let ghost = Club(
            id: "zzzzzzzzzz", name: "Ghost", bookId: "book1",
            bookTitle: "Middlemarch", bookAuthor: "George Eliot",
            inviteCode: "ABCD", createdAt: Date(), members: []
        )
        #expect(throws: CoreError.self) { try store.updateClub(ghost) }
    }

    @Test("snapshots write, list, read, and remove")
    func snapshotsRoundTrip() throws {
        let store = ClubStore(root: try temporaryRoot())
        let club = try create(store)
        let alice = snapshot("alice", "Alice")
        let bob = snapshot("bob", "Bob")
        try store.writeMemberSnapshot(alice, clubId: club.id)
        try store.writeMemberSnapshot(bob, clubId: club.id)

        #expect(try store.memberSnapshots(clubId: club.id).map(\.memberId) == ["alice", "bob"])
        #expect(try store.memberSnapshot(clubId: club.id, memberId: "alice") == alice)
        #expect(try store.memberSnapshot(clubId: club.id, memberId: "carol") == nil)

        // Rewriting replaces, never duplicates.
        var edited = bob
        edited.displayName = "Robert"
        try store.writeMemberSnapshot(edited, clubId: club.id)
        #expect(try store.memberSnapshot(clubId: club.id, memberId: "bob")?.displayName == "Robert")

        try store.removeMemberSnapshot(clubId: club.id, memberId: "bob")
        #expect(try store.memberSnapshots(clubId: club.id).map(\.memberId) == ["alice"])
    }

    @Test("a snapshot for a missing club is rejected")
    func snapshotMissingClubThrows() throws {
        let store = ClubStore(root: try temporaryRoot())
        #expect(throws: CoreError.self) {
            try store.writeMemberSnapshot(snapshot("alice", "Alice"), clubId: "zzzzzzzzzz")
        }
    }

    @Test("deleting a club removes its directory")
    func deleteClub() throws {
        let store = ClubStore(root: try temporaryRoot())
        let club = try create(store)
        try store.deleteClub(id: club.id)
        #expect(try store.listClubs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.clubDir(club.id)))
    }

    @Test("a missing club is an error")
    func missingClubThrows() throws {
        let store = ClubStore(root: try temporaryRoot())
        #expect(throws: CoreError.self) { _ = try store.getClub(id: "zzzzzzzzzz") }
    }
}

@Suite("AppConfig clubs")
struct AppConfigClubTests {
    private func temporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-config-clubs-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("spoiler protection defaults on and persists when toggled off")
    func spoilerProtectionPersists() throws {
        let dataDir = try temporaryDirectory().appendingPathComponent("data")

        var config = try AppConfig(dataDir: dataDir)
        #expect(config.clubSpoilerProtection)

        try config.setClubSpoilerProtection(false)
        #expect(!config.clubSpoilerProtection)

        let reloaded = try AppConfig(dataDir: dataDir)
        #expect(!reloaded.clubSpoilerProtection)
    }

    @Test("a config.json without the spoiler key keeps protection on")
    func missingSpoilerKeyDefaultsOn() throws {
        let base = try temporaryDirectory()
        let dataDir = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try #"{"library_root":"\#(base.appendingPathComponent("lib"))"}"#
            .write(
                toFile: dataDir.appendingPathComponent("config.json"),
                atomically: true, encoding: .utf8
            )

        #expect(try AppConfig(dataDir: dataDir).clubSpoilerProtection)
    }

    @Test("the club member id is generated once and persists with the name")
    func clubIdentityPersists() throws {
        let dataDir = try temporaryDirectory().appendingPathComponent("data")

        var config = try AppConfig(dataDir: dataDir)
        #expect(config.clubMemberId == nil)
        let first = try config.ensureClubMemberId()
        #expect(first.count == 10)
        #expect(try config.ensureClubMemberId() == first)

        try config.setClubDisplayName("Alice")
        let reloaded = try AppConfig(dataDir: dataDir)
        #expect(reloaded.clubMemberId == first)
        #expect(reloaded.clubDisplayName == "Alice")
    }
}
