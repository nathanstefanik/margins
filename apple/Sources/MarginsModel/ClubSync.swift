import Foundation
import MarginsCore

// CloudKit transport for private book clubs (docs/book-clubs-plan.md phase 3).
//
// `ClubSyncEngine` is the seam: the CloudKit implementation lives in
// `CloudKitClubSync.swift`, and tests drive an in-memory fake behind the
// same protocol, so join/sync/rotate logic is testable without an iCloud
// account. `ClubSync` is the orchestrator the apps call; it keeps the local
// `CoreStore` and the transport in step.
//
// Sync model: every member publishes exactly one snapshot record for
// themselves and the roster rides on the club record. Single-writer records
// mean a sync is just "pull remote copies and write them through the same
// local store paths a local save would use" — there is no field-level merge
// to get wrong.

public struct ClubInvite: Sendable, Equatable {
    public var code: String
    public var clubId: String
    public var clubName: String
    public var bookTitle: String
    public var shareURL: URL
    public var expiresAt: Date

    public init(
        code: String, clubId: String, clubName: String, bookTitle: String,
        shareURL: URL, expiresAt: Date
    ) {
        self.code = code
        self.clubId = clubId
        self.clubName = clubName
        self.bookTitle = bookTitle
        self.shareURL = shareURL
        self.expiresAt = expiresAt
    }
}

public struct ClubShare: Sendable, Equatable {
    public var clubId: String
    public var url: URL

    public init(clubId: String, url: URL) {
        self.clubId = clubId
        self.url = url
    }
}

public enum ClubSyncError: Error, LocalizedError, Sendable, Equatable {
    case invalidCode
    case unknownCode
    case expiredCode
    case notSignedIn
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return "That invite code doesn't look right."
        case .unknownCode: return "No club uses that invite code."
        case .expiredCode: return "That invite code has expired."
        case .notSignedIn: return "Sign in to iCloud to use book clubs."
        case let .transport(message): return message
        }
    }
}

public protocol ClubSyncEngine: Sendable {
    /// False for the local-only engine, which can move snapshots between
    /// local club members but cannot invite anyone.
    var supportsSharing: Bool { get }
    /// The local user's stable member id from the transport's account.
    func currentMemberId() async throws -> String
    /// Creates the shared club record and returns its URL. Idempotent: an
    /// existing share is returned as-is.
    func createShare(for club: Club) async throws -> ClubShare
    func shareURL(forClubId clubId: String) async throws -> URL?
    /// Accepts a share URL and returns the club record it carries.
    func acceptShare(url: URL) async throws -> Club
    func fetchClub(id: String) async throws -> Club?
    func publishClub(_ club: Club) async throws
    func publishSnapshot(_ snapshot: ClubMemberNotes, clubId: String) async throws
    func fetchSnapshots(clubId: String) async throws -> [ClubMemberNotes]
    func deleteSnapshot(clubId: String, memberId: String) async throws
    /// Removes a participant from the club's share (owner only; a no-op for
    /// members that are not CloudKit participants).
    func removeParticipant(clubId: String, memberId: String) async throws
    func publishInvite(_ invite: ClubInvite) async throws
    func lookupInvite(code: String) async throws -> ClubInvite?
    func revokeInvite(code: String) async throws
}

/// The apps' club entry point: local store plus transport.
public struct ClubSync: Sendable {
    /// How long an unpublished code stays resolvable.
    public static let inviteLifetime: TimeInterval = 14 * 24 * 60 * 60

    public let store: CoreStore
    private let engine: any ClubSyncEngine

    public init(store: CoreStore, engine: any ClubSyncEngine) {
        self.store = store
        self.engine = engine
    }

    /// The production transport.
    public static func live(store: CoreStore) -> ClubSync {
        ClubSync(store: store, engine: CloudKitClubSyncEngine())
    }

    /// CloudKit when an iCloud account is usable, otherwise the local-only
    /// engine so clubs still work on an unsigned build. This is what both
    /// apps construct.
    public static func automatic(store: CoreStore) async -> ClubSync {
        let cloud = ClubSync.live(store: store)
        if (try? await cloud.currentMemberId()) != nil {
            return cloud
        }
        let identity = (try? await store.clubIdentity())
            ?? ClubIdentity(memberId: "local")
        return ClubSync(
            store: store,
            engine: LocalClubSyncEngine(store: store, memberId: identity.memberId)
        )
    }

    /// True when the transport can invite and sync with other people.
    public var supportsSharing: Bool { engine.supportsSharing }

    /// The local user's transport member id.
    public func currentMemberId() async throws -> String {
        try await engine.currentMemberId()
    }

    /// Creates a local club, publishes its shared record, and indexes the
    /// invite code for lookups.
    public func createClub(
        bookId: String, name: String, memberId: String, displayName: String
    ) async throws -> (club: Club, shareURL: URL) {
        let club = try await store.createClub(
            bookId: bookId, name: name, adminId: memberId, adminName: displayName
        )
        let share = try await engine.createShare(for: club)
        try await engine.publishInvite(invite(for: club, shareURL: share.url))
        return (club, share.url)
    }

    /// Joins by invite code: resolves the code, accepts the share, merges
    /// the roster, publishes the joiner's snapshot, and stores it all
    /// locally.
    public func joinClub(
        code: String, memberId: String, displayName: String
    ) async throws -> Club {
        guard let normalized = ClubCode.normalize(code) else {
            throw ClubSyncError.invalidCode
        }
        guard let invite = try await engine.lookupInvite(code: normalized) else {
            throw ClubSyncError.unknownCode
        }
        guard invite.expiresAt > Date() else { throw ClubSyncError.expiredCode }

        var club = try await engine.acceptShare(url: invite.shareURL)
        if !club.members.contains(where: { $0.id == memberId }) {
            club.members.append(
                ClubMember(
                    id: memberId, displayName: displayName, role: .member,
                    joinedAt: RFC3339.now()
                )
            )
        }
        try await store.saveClub(club)
        try await engine.publishClub(club)

        let snapshot = try await store.buildClubMemberSnapshot(
            clubId: club.id, memberId: memberId, displayName: displayName
        )
        try await store.saveClubMemberSnapshot(clubId: club.id, snapshot: snapshot)
        try await engine.publishSnapshot(snapshot, clubId: club.id)
        return club
    }

    /// Pulls the shared club record and every member snapshot, stores them
    /// locally, and returns the merged view for `viewerId`.
    @discardableResult
    public func syncClub(
        clubId: String, viewerId: String, spoilerEnabled: Bool? = nil
    ) async throws -> ClubNotes {
        if let remote = try await engine.fetchClub(id: clubId) {
            try await store.saveClub(remote)
        }
        for snapshot in try await engine.fetchSnapshots(clubId: clubId) {
            try await store.saveClubMemberSnapshot(clubId: clubId, snapshot: snapshot)
        }
        return try await store.clubNotes(
            clubId: clubId, viewerId: viewerId, spoilerEnabled: spoilerEnabled
        )
    }

    /// Rebuilds the member's local snapshot from their notes, then publishes
    /// it.
    @discardableResult
    public func publishOwnSnapshot(
        clubId: String, memberId: String, displayName: String
    ) async throws -> ClubMemberNotes {
        let snapshot = try await store.refreshClubMemberSnapshot(
            clubId: clubId, memberId: memberId, displayName: displayName
        )
        try await engine.publishSnapshot(snapshot, clubId: clubId)
        return snapshot
    }

    /// Rotates the invite code, revokes the old index entry, and indexes the
    /// new one. A missing share URL just means no code is published yet.
    @discardableResult
    public func rotateInviteCode(clubId: String) async throws -> String {
        let previous = try await store.getClub(id: clubId).inviteCode
        let code = try await store.rotateClubInviteCode(clubId: clubId)
        let club = try await store.getClub(id: clubId)
        try await engine.publishClub(club)
        try await engine.revokeInvite(code: previous)
        if let url = try await engine.shareURL(forClubId: clubId) {
            try await engine.publishInvite(invite(for: club, shareURL: url))
        }
        return code
    }

    /// Removes a member locally, remotely, and from the share. Role
    /// enforcement belongs to the UI and the transport; this performs the
    /// mechanics.
    public func removeMember(clubId: String, memberId: String) async throws -> Club {
        var club = try await store.getClub(id: clubId)
        club.members.removeAll { $0.id == memberId }
        try await store.saveClub(club)
        try await store.removeClubMemberSnapshot(clubId: clubId, memberId: memberId)
        try await engine.deleteSnapshot(clubId: clubId, memberId: memberId)
        try await engine.removeParticipant(clubId: clubId, memberId: memberId)
        try await engine.publishClub(club)
        return club
    }

    /// Resolves an invite code for display before joining.
    public func lookupInvite(code: String) async throws -> ClubInvite? {
        guard let normalized = ClubCode.normalize(code) else {
            throw ClubSyncError.invalidCode
        }
        return try await engine.lookupInvite(code: normalized)
    }

    private func invite(for club: Club, shareURL: URL, now: Date = Date()) -> ClubInvite {
        ClubInvite(
            code: club.inviteCode,
            clubId: club.id,
            clubName: club.name,
            bookTitle: club.bookTitle,
            shareURL: shareURL,
            expiresAt: now.addingTimeInterval(Self.inviteLifetime)
        )
    }
}
