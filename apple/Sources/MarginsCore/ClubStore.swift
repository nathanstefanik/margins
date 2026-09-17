import Foundation

// Local club storage: `{data_dir}/clubs/{club_id}/club.json` plus one
// snapshot per member under `members/` (docs/storage.md). Club state is
// social, not library content — it syncs through CloudKit
// (docs/book-clubs-plan.md phase 3), never through the library folder — so
// it lives in the data directory and is read and written only here.
//
// One file per member snapshot keeps every writer single-writer: two members
// can never race on the same snapshot file, which is what makes CloudKit's
// last-writer-wins acceptable later.
public struct ClubStore: Sendable {
    public let root: String

    public init(root: String) {
        self.root = root
    }

    // MARK: Clubs

    /// Creates a club reading exactly one book, with `admin` as its first
    /// member and freshly generated id and invite code.
    public func createClub(
        name: String,
        bookId: String,
        bookTitle: String,
        bookAuthor: String,
        adminId: String,
        adminName: String
    ) throws -> Club {
        var id = CoreID.newID()
        while Files.exists(clubDir(id)) { id = CoreID.newID() }

        let now = RFC3339.now()
        let club = Club(
            id: id,
            name: name,
            bookId: bookId,
            bookTitle: bookTitle,
            bookAuthor: bookAuthor,
            inviteCode: try uniqueInviteCode(),
            createdAt: now,
            ownerMemberId: adminId,
            members: [
                ClubMember(
                    id: adminId, displayName: adminName, role: .admin, joinedAt: now
                )
            ]
        )
        try writeClub(club)
        return club
    }

    /// Every club, newest first. Malformed club files surface as errors
    /// rather than silently disappearing from the list.
    public func listClubs() throws -> [Club] {
        guard Files.exists(root) else { return [] }
        var clubs: [Club] = []
        for directory in try FileStore.contents(ofDirectory: root) {
            let name = (directory as NSString).lastPathComponent
            guard !name.hasPrefix("."), Files.isDirectory(directory) else { continue }
            let path = directory.appendingPathComponent("club.json")
            guard FileStore.exists(path) else { continue }
            clubs.append(try readClub(at: path))
        }
        return clubs.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    public func getClub(id: String) throws -> Club {
        let path = clubDir(id).appendingPathComponent("club.json")
        guard FileStore.exists(path) else {
            throw CoreError.library("club not found: \(id)")
        }
        return try readClub(at: path)
    }

    /// Writes the club record, creating its directory and `members/` if
    /// needed. Used for creation and roster/code updates alike.
    public func writeClub(_ club: Club) throws {
        let directory = clubDir(club.id)
        try Files.createDirectory(directory.appendingPathComponent("members"))
        try FileStore.writeData(
            MarginsJSON.encode(club), to: directory.appendingPathComponent("club.json")
        )
    }

    /// Persists an update to an existing club; a missing club is an error,
    /// not an upsert.
    public func updateClub(_ club: Club) throws {
        _ = try getClub(id: club.id)
        try writeClub(club)
    }

    public func deleteClub(id: String) throws {
        let directory = clubDir(id)
        if Files.exists(directory) { try Files.remove(directory) }
    }

    /// Replaces the club's invite code with one no other club uses, always
    /// different from the current code, and persists it.
    public func rotateInviteCode(clubId: String) throws -> Club {
        var club = try getClub(id: clubId)
        club.inviteCode = try uniqueInviteCode(excluding: club.inviteCode)
        try writeClub(club)
        return club
    }

    // MARK: Snapshots

    /// Every member snapshot, sorted by member id for deterministic output.
    public func memberSnapshots(clubId: String) throws -> [ClubMemberNotes] {
        let directory = membersDir(clubId)
        guard Files.exists(directory) else { return [] }
        var snapshots: [ClubMemberNotes] = []
        for path in try FileStore.contents(ofDirectory: directory) where path.hasSuffix(".json") {
            snapshots.append(
                try MarginsJSON.decode(ClubMemberNotes.self, from: FileStore.readData(path))
            )
        }
        return snapshots.sorted { $0.memberId < $1.memberId }
    }

    public func memberSnapshot(clubId: String, memberId: String) throws -> ClubMemberNotes? {
        let path = snapshotPath(clubId: clubId, memberId: memberId)
        guard FileStore.exists(path) else { return nil }
        return try MarginsJSON.decode(ClubMemberNotes.self, from: FileStore.readData(path))
    }

    /// Writes one member's snapshot over any previous one. The club must
    /// exist: a snapshot never resurrects a deleted club.
    public func writeMemberSnapshot(_ snapshot: ClubMemberNotes, clubId: String) throws {
        _ = try getClub(id: clubId)
        try Files.createDirectory(membersDir(clubId))
        try FileStore.writeData(
            MarginsJSON.encode(snapshot),
            to: snapshotPath(clubId: clubId, memberId: snapshot.memberId)
        )
    }

    public func removeMemberSnapshot(clubId: String, memberId: String) throws {
        let path = snapshotPath(clubId: clubId, memberId: memberId)
        if FileStore.exists(path) { try FileStore.remove(path) }
    }

    // MARK: Paths

    public func clubDir(_ clubId: String) -> String {
        root.appendingPathComponent(clubId)
    }

    private func membersDir(_ clubId: String) -> String {
        clubDir(clubId).appendingPathComponent("members")
    }

    private func snapshotPath(clubId: String, memberId: String) -> String {
        membersDir(clubId).appendingPathComponent("\(memberId).json")
    }

    private func readClub(at path: String) throws -> Club {
        do {
            return try MarginsJSON.decode(Club.self, from: FileStore.readData(path))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.library("json error: \(error.localizedDescription)")
        }
    }

    private func uniqueInviteCode(excluding existing: String? = nil) throws -> String {
        let taken = Set(try listClubs().map(\.inviteCode))
        var code = ClubCode.generate()
        while code == existing || taken.contains(code) { code = ClubCode.generate() }
        return code
    }
}
