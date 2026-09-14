import CloudKit
import Foundation
import MarginsCore

// The CloudKit implementation of `ClubSyncEngine`.
//
// Record model (docs/book-clubs-plan.md):
// - One custom zone per club, `club-{clubId}`, holding the `Club` root
//   record and one `Snapshot` record per member. The share hangs off the
//   club record, so accepting it grants the snapshots too.
// - Snapshot record names are `snap-{memberId}`. CloudKit user record
//   names start with `_`, which is reserved and rejected as a record ID
//   (`invalid id string`); the prefix keeps the ID legal. `memberId` still
//   lives on the record as a field.
// - `ClubInvite` records live in the public database, keyed by invite code;
//   they carry the share URL and expire. The code is a handle, not a
//   security boundary — accepting the share is the gate.
//
// v1 pulls whole records on demand instead of tracking server change
// tokens: a club is a handful of members and one book's notes, far below the
// point where a full fetch matters. If that changes, add a
// `CKServerChangeToken` per club and a `fetchChanges` engine call.
//
// The `clubId` field on both record types must be queryable in the
// development schema (CloudKit Dashboard) for the participant-side queries.
public actor CloudKitClubSyncEngine: ClubSyncEngine {
    public static let defaultContainerIdentifier = "iCloud.io.github.nathanstefanik.margins"

    enum RecordType {
        static let club = "Club"
        static let snapshot = "Snapshot"
        static let invite = "ClubInvite"
    }

    private let container: CKContainer
    private let privateDB: CKDatabase
    private let sharedDB: CKDatabase
    private let publicDB: CKDatabase
    private var zoneCache: [String: CKRecordZone.ID] = [:]

    public init(
        containerIdentifier: String = CloudKitClubSyncEngine.defaultContainerIdentifier
    ) {
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
        self.publicDB = container.publicCloudDatabase
    }

    public nonisolated var supportsSharing: Bool { true }

    // MARK: Identity

    public func currentMemberId() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchUserRecordID { recordID, error in
                if let recordID {
                    continuation.resume(returning: recordID.recordName)
                } else {
                    _ = error
                    continuation.resume(throwing: ClubSyncError.notSignedIn)
                }
            }
        }
    }

    // MARK: Club records

    public func createShare(for club: Club) async throws -> ClubShare {
        let zoneID = ownerZoneID(club.id)
        try await ensureZone(zoneID)

        let recordID = CKRecord.ID(recordName: club.id, zoneID: zoneID)
        if let existing = try? await existingShare(rootRecordID: recordID, in: privateDB),
           let url = existing.url
        {
            zoneCache[club.id] = zoneID
            return ClubShare(clubId: club.id, url: url)
        }

        let record = CKRecord(recordType: RecordType.club, recordID: recordID)
        record["clubId"] = club.id as CKRecordValue
        record["payload"] = try payload(of: club) as NSData
        // Root alone first: a single batch that asks CloudKit to create
        // both the Club type and the system cloudkit.share type fails with
        // a bare "Atomic failure" in the development environment. Saving
        // the root here lets development create the Club type, so the
        // Club + share batch below only has one new type left.
        let rootRecord = try await saveRecord(record, in: privateDB)

        let share = CKShare(rootRecord: rootRecord)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = "\(club.name) — Margins" as CKRecordValue
        // A new share must be saved together with its root record in the
        // same modify batch (CKShare.init(rootRecord:)). A share-only save
        // is rejected with "An added share is being saved without its
        // rootRecord", which also means development never creates the
        // cloudkit.share system type for production to deploy.
        let savedShare = try await saveShare(
            rootRecord: rootRecord, share: share, in: privateDB
        )

        zoneCache[club.id] = zoneID
        if let url = savedShare.url {
            return ClubShare(clubId: club.id, url: url)
        }
        // Reading the share back covers a save result without its URL.
        guard let saved = try? await existingShare(rootRecordID: recordID, in: privateDB),
              let url = saved.url
        else {
            throw ClubSyncError.transport("CloudKit did not return a share URL.")
        }
        return ClubShare(clubId: club.id, url: url)
    }

    public func shareURL(forClubId clubId: String) async throws -> URL? {
        guard let zoneID = try? await zoneID(forClubId: clubId) else { return nil }
        let (database, recordID) = databaseAndRecordID(zone: zoneID, recordName: clubId)
        return try? await existingShare(rootRecordID: recordID, in: database)?.url
    }

    public func acceptShare(url: URL) async throws -> Club {
        let metadata = try await shareMetadata(for: url)
        _ = try await accept(metadata)
        let clubId = metadata.rootRecordID.recordName
        // Remember the shared zone now: later shared-database reads must
        // be scoped to it (a zone-wide query is not supported there).
        zoneCache[clubId] = metadata.rootRecordID.zoneID
        guard let club = try await fetchClub(id: clubId) else {
            throw ClubSyncError.transport("The shared club could not be read.")
        }
        return club
    }

    public func fetchClub(id: String) async throws -> Club? {
        if let record = try? await fetchRecord(
            CKRecord.ID(recordName: id, zoneID: ownerZoneID(id)), in: privateDB
        ) {
            zoneCache[id] = record.recordID.zoneID
            return try decode(Club.self, from: record)
        }
        guard let record = try await sharedClubRecord(id: id) else {
            return nil
        }
        return try decode(Club.self, from: record)
    }

    public func publishClub(_ club: Club) async throws {
        let zoneID = try await zoneID(forClubId: club.id)
        let (database, recordID) = databaseAndRecordID(zone: zoneID, recordName: club.id)
        let record = (try? await fetchRecord(recordID, in: database))
            ?? CKRecord(recordType: RecordType.club, recordID: recordID)
        record["clubId"] = club.id as CKRecordValue
        record["payload"] = try payload(of: club) as NSData
        _ = try await saveRecord(record, in: database)
    }

    // MARK: Snapshots

    public func publishSnapshot(_ snapshot: ClubMemberNotes, clubId: String) async throws {
        let zoneID = try await zoneID(forClubId: clubId)
        let (database, recordID) = databaseAndRecordID(
            zone: zoneID, recordName: Self.snapshotRecordName(snapshot.memberId)
        )
        let record = (try? await fetchRecord(recordID, in: database))
            ?? CKRecord(recordType: RecordType.snapshot, recordID: recordID)
        record["clubId"] = clubId as CKRecordValue
        record["memberId"] = snapshot.memberId as CKRecordValue
        record["payload"] = try payload(of: snapshot) as NSData
        _ = try await saveRecord(record, in: database)
    }

    public func fetchSnapshots(clubId: String) async throws -> [ClubMemberNotes] {
        let zoneID = try await zoneID(forClubId: clubId)
        let query = CKQuery(
            recordType: RecordType.snapshot,
            predicate: NSPredicate(format: "clubId == %@", clubId)
        )
        return try await records(
            matching: query, in: database(for: zoneID), zoneID: zoneID
        ).map {
            try decode(ClubMemberNotes.self, from: $0)
        }
    }

    public func deleteSnapshot(clubId: String, memberId: String) async throws {
        let zoneID = try await zoneID(forClubId: clubId)
        let (database, recordID) = databaseAndRecordID(
            zone: zoneID, recordName: Self.snapshotRecordName(memberId)
        )
        try? await deleteRecord(recordID, in: database)
    }

    public func deleteClub(id: String) async throws {
        zoneCache[id] = nil
        // The owner created `club-{id}` in their private DB; deleting the
        // zone drops the club record, every snapshot, and the share. A
        // missing zone is already gone (local-only leftover, or a
        // participant with no private copy).
        try await deleteZone(ownerZoneID(id))
    }

    public func removeParticipant(clubId: String, memberId: String) async throws {
        guard let zoneID = try? await zoneID(forClubId: clubId),
              let share = try? await existingShare(
                  rootRecordID: CKRecord.ID(recordName: clubId, zoneID: zoneID),
                  in: privateDB
              ),
              let participant = share.participants.first(where: {
                  $0.userIdentity.userRecordID?.recordName == memberId
              })
        else { return }
        // A link share (`publicPermission` other than `.none`) has no
        // per-participant list to modify, so CloudKit cannot revoke one
        // person's access; removing the roster entry and snapshot is the
        // enforceable part (docs/book-clubs-plan.md).
        guard share.publicPermission == .none else { return }
        share.removeParticipant(participant)
        _ = try await saveRecord(share, in: privateDB)
    }

    // MARK: Invites

    public func publishInvite(_ invite: ClubInvite) async throws {
        let record = CKRecord(
            recordType: RecordType.invite,
            recordID: CKRecord.ID(recordName: invite.code)
        )
        record["clubId"] = invite.clubId as CKRecordValue
        record["clubName"] = invite.clubName as CKRecordValue
        record["bookId"] = invite.bookId as CKRecordValue
        record["bookTitle"] = invite.bookTitle as CKRecordValue
        record["shareURL"] = invite.shareURL.absoluteString as CKRecordValue
        record["expiresAt"] = invite.expiresAt as NSDate
        _ = try await saveRecord(record, in: publicDB)
    }

    public func lookupInvite(code: String) async throws -> ClubInvite? {
        guard let record = try? await fetchRecord(
            CKRecord.ID(recordName: code), in: publicDB
        ) else { return nil }
        return try decodeInvite(record, code: code)
    }

    public func revokeInvite(code: String) async throws {
        try? await deleteRecord(CKRecord.ID(recordName: code), in: publicDB)
    }

    // MARK: Plumbing

    private func ownerZoneID(_ clubId: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "club-\(clubId)", ownerName: CKCurrentUserDefaultName)
    }

    /// The zone holding a club: the deterministic private zone for the
    /// owner, otherwise the shared zone discovered from the club record.
    private func zoneID(forClubId clubId: String) async throws -> CKRecordZone.ID {
        if let cached = zoneCache[clubId] { return cached }
        if let record = try? await fetchRecord(
            CKRecord.ID(recordName: clubId, zoneID: ownerZoneID(clubId)), in: privateDB
        ) {
            zoneCache[clubId] = record.recordID.zoneID
            return record.recordID.zoneID
        }
        if let record = try await sharedClubRecord(id: clubId) {
            return record.recordID.zoneID
        }
        throw ClubSyncError.transport("Club not found in CloudKit: \(clubId)")
    }

    /// Finds a club in the shared database. A participant's zone is only
    /// known right after accepting the share (or after rediscovering it),
    /// and the shared database rejects zone-wide queries, so read through
    /// the cached zone when present and otherwise query each shared zone.
    private func sharedClubRecord(id: String) async throws -> CKRecord? {
        if let cached = zoneCache[id],
           let record = try? await fetchRecord(
               CKRecord.ID(recordName: id, zoneID: cached), in: sharedDB
           ) {
            return record
        }
        let query = CKQuery(
            recordType: RecordType.club,
            predicate: NSPredicate(format: "clubId == %@", id)
        )
        for zone in try await sharedDB.allRecordZones() {
            if let record = try await records(
                matching: query, in: sharedDB, zoneID: zone.zoneID
            ).first {
                zoneCache[id] = zone.zoneID
                return record
            }
        }
        return nil
    }

    private func database(for zone: CKRecordZone.ID) -> CKDatabase {
        zone.ownerName == CKCurrentUserDefaultName ? privateDB : sharedDB
    }

    private func databaseAndRecordID(
        zone: CKRecordZone.ID, recordName: String
    ) -> (CKDatabase, CKRecord.ID) {
        (database(for: zone), CKRecord.ID(recordName: recordName, zoneID: zone))
    }

    /// CloudKit record names cannot start with `_` (system-reserved). User
    /// record names always do, so snapshots cannot be keyed by member id.
    private static func snapshotRecordName(_ memberId: String) -> String {
        "snap-\(memberId)"
    }

    private func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        // Saving an existing zone is a success, so this is create-or-adopt.
        _ = try await withCheckedThrowingContinuation { continuation in
            privateDB.save(CKRecordZone(zoneID: zoneID)) { zone, error in
                if let zone {
                    continuation.resume(returning: zone)
                } else {
                    continuation.resume(
                        throwing: error ?? ClubSyncError.transport("CloudKit zone save failed.")
                    )
                }
            }
        }
    }

    private func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            operation.perShareMetadataResultBlock = { _, result in
                continuation.resume(with: result)
            }
            container.add(operation)
        }
    }

    private func accept(_ metadata: CKShare.Metadata) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            container.accept(metadata) { share, error in
                if let share {
                    continuation.resume(returning: share)
                } else {
                    continuation.resume(
                        throwing: error ?? ClubSyncError.transport("CloudKit did not accept the share.")
                    )
                }
            }
        }
    }

    /// A root record's share, resolved through its `share` reference (the
    /// property is a reference, so the share record is a second fetch).
    private func existingShare(
        rootRecordID: CKRecord.ID, in database: CKDatabase
    ) async throws -> CKShare? {
        guard let root = try? await fetchRecord(rootRecordID, in: database),
              let reference = root.share,
              let shareRecord = try? await fetchRecord(reference.recordID, in: database)
        else { return nil }
        return shareRecord as? CKShare
    }

    private func fetchRecord(
        _ recordID: CKRecord.ID, in database: CKDatabase
    ) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? ClubSyncError.transport(
                                "CloudKit returned no record: \(recordID.recordName)"
                            )
                    )
                }
            }
        }
    }

    private func saveRecord(
        _ record: CKRecord, in database: CKDatabase
    ) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { saved, error in
                if let saved {
                    continuation.resume(returning: saved)
                } else {
                    continuation.resume(
                        throwing: ClubSyncError.transport(
                            Self.describe(error, saving: record.recordID.recordName)
                        )
                    )
                }
            }
        }
    }

    /// Saves a new share in the same atomic batch as its root record, which
    /// is what CloudKit requires for share creation. The share comes back
    /// from the save results; the in-memory object is not updated.
    private func saveShare(
        rootRecord: CKRecord, share: CKShare, in database: CKDatabase
    ) async throws -> CKShare {
        do {
            let result = try await database.modifyRecords(
                saving: [rootRecord, share], deleting: [],
                savePolicy: .changedKeys, atomically: true
            )
            for value in result.saveResults.values {
                if case let .success(saved) = value, let savedShare = saved as? CKShare {
                    return savedShare
                }
            }
            throw ClubSyncError.transport(
                "CloudKit returned no share: \(share.recordID.recordName)"
            )
        } catch let error as ClubSyncError {
            throw error
        } catch {
            throw ClubSyncError.transport(
                Self.describe(error, saving: share.recordID.recordName)
            )
        }
    }

    /// A per-record failure description. Batch failures carry the real
    /// per-record reason in the partial errors; `localizedDescription`
    /// alone hides them (a bare "Atomic failure").
    private static func describe(_ error: (any Error)?, saving recordName: String) -> String {
        guard let error else {
            return "CloudKit returned no record: \(recordName)"
        }
        guard let ckError = error as? CKError,
              let partials = ckError.partialErrorsByItemID,
              !partials.isEmpty
        else {
            return error.localizedDescription
        }
        let details = partials
            .map { key, value in
                "\(key): \((value as? CKError)?.localizedDescription ?? value.localizedDescription)"
            }
            .sorted()
            .joined(separator: "; ")
        return "\(error.localizedDescription) [\(details)]"
    }

    private func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            privateDB.delete(withRecordZoneID: zoneID) { _, error in
                if let ckError = error as? CKError,
                   ckError.code == .zoneNotFound || ckError.code == .unknownItem
                {
                    continuation.resume(returning: ())
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func deleteRecord(
        _ recordID: CKRecord.ID, in database: CKDatabase
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            database.delete(withRecordID: recordID) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func records(
        matching query: CKQuery, in database: CKDatabase, zoneID: CKRecordZone.ID? = nil
    ) async throws -> [CKRecord] {
        var collected: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page: (
                matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                page = try await database.records(continuingMatchFrom: cursor)
            } else if let zoneID {
                // The shared database requires a zone-scoped query.
                page = try await database.records(matching: query, inZoneWith: zoneID)
            } else {
                page = try await database.records(matching: query)
            }
            for (_, recordResult) in page.matchResults {
                collected.append(try recordResult.get())
            }
            cursor = page.queryCursor
        } while cursor != nil
        return collected
    }

    private func payload<T: Encodable>(of value: T) throws -> Data {
        try MarginsJSON.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: CKRecord) throws -> T {
        guard let data = recordData(record) else {
            throw ClubSyncError.transport(
                "CloudKit record has no payload: \(record.recordID.recordName)"
            )
        }
        return try MarginsJSON.decode(type, from: data)
    }

    private func decodeInvite(_ record: CKRecord, code: String) throws -> ClubInvite {
        guard let clubId = record["clubId"] as? String,
              let clubName = record["clubName"] as? String,
              let bookId = record["bookId"] as? String,
              let bookTitle = record["bookTitle"] as? String,
              let rawURL = record["shareURL"] as? String,
              let url = URL(string: rawURL),
              let expiresAt = record["expiresAt"] as? Date
        else {
            throw ClubSyncError.transport("Malformed invite record: \(code)")
        }
        return ClubInvite(
            code: code, clubId: clubId, clubName: clubName,
            bookId: bookId, bookTitle: bookTitle, shareURL: url, expiresAt: expiresAt
        )
    }

    /// CKRecord hands `Data` values back as `NSData`; accept either.
    private func recordData(_ record: CKRecord) -> Data? {
        if let data = record["payload"] as? Data { return data }
        if let data = record["payload"] as? NSData { return data as Data }
        return nil
    }
}
