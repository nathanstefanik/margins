import Foundation
import MarginsCore
import os
#if os(macOS)
import Security
#endif

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
    public var bookId: String
    public var bookTitle: String
    public var shareURL: URL
    public var expiresAt: Date

    public init(
        code: String, clubId: String, clubName: String, bookId: String,
        bookTitle: String, shareURL: URL, expiresAt: Date
    ) {
        self.code = code
        self.clubId = clubId
        self.clubName = clubName
        self.bookId = bookId
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
    /// The club's book is not in the local library yet.
    case bookMissing(String)
    case notSignedIn
    /// The transport could not create the club's share — a CloudKit
    /// configuration or service failure, not something the reader can fix.
    case sharingUnavailable
    /// The deployed CloudKit schema does not know about sharing (the system
    /// `cloudkit.share` type is missing). Retrying cannot help; the schema
    /// has to be deployed to production.
    case sharingSchemaMissing
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return "That invite code doesn't look right."
        case .unknownCode: return "No club uses that invite code."
        case .expiredCode: return "That invite code has expired."
        case let .bookMissing(title):
            return "Import \"\(title)\" into your library, then join the club."
        case .notSignedIn: return "Sign in to iCloud to use book clubs."
        case .sharingUnavailable:
            return "Book club sharing is unavailable right now. Try again later."
        case .sharingSchemaMissing:
            return "Book club sharing isn't set up in this app's iCloud database yet. The CloudKit sharing types still need to be deployed."
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
    /// Drops the club's CloudKit zone (or no-ops on the local engine).
    func deleteClub(id: String) async throws
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

    private static let log = Logger(
        subsystem: "io.github.nathanstefanik.margins", category: "clubs"
    )

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

    /// True when the running process carries the iCloud container
    /// entitlement, i.e. when constructing a `CKContainer` is safe.
    ///
    /// The ubiquity token alone cannot answer this on macOS: it is non-nil
    /// even for an ad-hoc signed bundle with no entitlements, and
    /// `CKContainer(identifier:)` traps in that state. The entitlement is
    /// the only reliable signal before the trap.
    public static func cloudKitIsUsable() -> Bool {
        #if os(macOS)
        guard FileManager.default.ubiquityIdentityToken != nil,
              let task = SecTaskCreateFromSelf(nil)
        else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        )
        return (value as? [String])?.isEmpty == false
        #else
        return FileManager.default.ubiquityIdentityToken != nil
        #endif
    }

    /// CloudKit when an iCloud account is usable, otherwise the local-only
    /// engine so clubs still work on an unsigned build. This is what both
    /// apps construct. A signed-in user whose network is down stays on
    /// CloudKit (operations surface the error and can be retried) rather
    /// than silently turning the club local for the session.
    public static func automatic(store: CoreStore) async -> ClubSync {
        guard cloudKitIsUsable() else {
            let identity = (try? await store.clubIdentity())
                ?? ClubIdentity(memberId: "local")
            return ClubSync(
                store: store,
                engine: LocalClubSyncEngine(store: store, memberId: identity.memberId)
            )
        }
        let cloud = ClubSync.live(store: store)
        if let memberId = try? await cloud.currentMemberId() {
            // The transport id is the club identity: persist it so offline
            // launches and local clubs agree on who "you" are, migrating
            // any clubs created under a generated local id.
            try? await store.adoptClubMemberId(memberId)
        }
        return cloud
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
        let share: ClubShare
        do {
            share = try await engine.createShare(for: club)
        } catch {
            // A club without a share is one nobody can join: roll the local
            // record back rather than leaving an orphan behind. Retrying is
            // useless when the deployed schema has no sharing types, so
            // that failure gets its own message; the rest stay generic and
            // the raw CloudKit text goes to the log.
            Self.log.error(
                "club share creation failed: \(String(describing: error), privacy: .public)"
            )
            try? await store.deleteClub(id: club.id)
            if Self.isMissingShareSchema(error) {
                throw ClubSyncError.sharingSchemaMissing
            }
            throw ClubSyncError.sharingUnavailable
        }
        try await engine.publishInvite(invite(for: club, shareURL: share.url))
        return (club, share.url)
    }

    /// CloudKit rejects records whose types (custom or the system
    /// `cloudkit.share`) are absent from the deployed environment. The
    /// message text is the only structured signal the transport wraps.
    private static func isMissingShareSchema(_ error: any Error) -> Bool {
        let message = switch error {
        case let ClubSyncError.transport(text): text
        default: String(describing: error)
        }
        let lowered = message.lowercased()
        return lowered.contains("production schema")
            || lowered.contains("development schema")
            || lowered.contains("cannot create new type")
            || lowered.contains("did not find record type")
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
        // Check the book before accepting the share: a late failure would
        // leave the share accepted and the club half-joined.
        guard (try? await store.getBook(id: invite.bookId)) != nil else {
            throw ClubSyncError.bookMissing(invite.bookTitle)
        }

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

    /// Revokes the invite, drops the CloudKit zone, then deletes the local
    /// club directory. A CloudKit failure is logged and the local copy is
    /// still removed so the owner is not stuck with a club they cannot
    /// delete; the invite is revoked first so the code stops resolving.
    public func deleteClub(id: String) async throws {
        let inviteCode = (try? await store.getClub(id: id))?.inviteCode
        if let inviteCode {
            try? await engine.revokeInvite(code: inviteCode)
        }
        do {
            try await engine.deleteClub(id: id)
        } catch {
            Self.log.error(
                "club cloud delete failed: \(String(describing: error), privacy: .public)"
            )
        }
        try await store.deleteClub(id: id)
    }

    /// Drops the member from the roster and snapshot, then deletes the
    /// local club copy. The CloudKit zone stays: only the owner can
    /// delete the club for everyone.
    public func leaveClub(id: String, memberId: String) async throws {
        _ = try await removeMember(clubId: id, memberId: memberId)
        try await store.deleteClub(id: id)
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
            bookId: club.bookId,
            bookTitle: club.bookTitle,
            shareURL: shareURL,
            expiresAt: now.addingTimeInterval(Self.inviteLifetime)
        )
    }
}
