import Foundation
import MarginsCore

// A local-only transport: clubs work on this device without an iCloud
// account or a CloudKit entitlement (the ad-hoc-signed macOS build).
// Snapshots flow through the same store paths the apps already write, so a
// user can create a club, write notes, and see the merged view.
//
// Invites are process-local and therefore deliberately useless: joining
// another person's club needs the real transport, and the UI hides invite
// affordances when `supportsSharing` is false.
public actor LocalClubSyncEngine: ClubSyncEngine {
    private let store: CoreStore
    private let memberId: String
    private var invites: [String: ClubInvite] = [:]

    public init(store: CoreStore, memberId: String) {
        self.store = store
        self.memberId = memberId
    }

    public nonisolated var supportsSharing: Bool { false }

    public func currentMemberId() async throws -> String { memberId }

    public func createShare(for club: Club) async throws -> ClubShare {
        ClubShare(clubId: club.id, url: localURL(for: club.id))
    }

    public func shareURL(forClubId clubId: String) async throws -> URL? {
        localURL(for: clubId)
    }

    public func acceptShare(url: URL) async throws -> Club {
        do {
            return try await store.getClub(id: url.lastPathComponent)
        } catch {
            throw ClubSyncError.unknownCode
        }
    }

    public func fetchClub(id: String) async throws -> Club? {
        try? await store.getClub(id: id)
    }

    public func publishClub(_ club: Club) async throws {
        try await store.saveClub(club)
    }

    public func publishSnapshot(_ snapshot: ClubMemberNotes, clubId: String) async throws {
        try await store.saveClubMemberSnapshot(clubId: clubId, snapshot: snapshot)
    }

    public func fetchSnapshots(clubId: String) async throws -> [ClubMemberNotes] {
        try await store.clubMemberSnapshots(clubId: clubId)
    }

    public func deleteSnapshot(clubId: String, memberId: String) async throws {
        try await store.removeClubMemberSnapshot(clubId: clubId, memberId: memberId)
    }

    public func removeParticipant(clubId: String, memberId: String) async throws {}

    public func publishInvite(_ invite: ClubInvite) async throws {
        invites[invite.code] = invite
    }

    public func lookupInvite(code: String) async throws -> ClubInvite? {
        invites[code]
    }

    public func revokeInvite(code: String) async throws {
        invites[code] = nil
    }

    private func localURL(for clubId: String) -> URL {
        URL(string: "margins-local://club/\(clubId)")!
    }
}
