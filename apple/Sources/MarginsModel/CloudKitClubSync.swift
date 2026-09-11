import CloudKit
import Foundation
import MarginsCore

// The CloudKit implementation of `ClubSyncEngine`.
//
// Record model (docs/book-clubs-plan.md):
// - One custom zone per club, `club-{clubId}`, holding the `Club` root
//   record and one `Snapshot` record per member. The share hangs off the
//   club record, so accepting it grants the snapshots too.
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

        let share = CKShare(rootRecord: record)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = "\(club.name) — Margins" as CKRecordValue
        _ = try await modifyRecords(saving: [record, share], in: privateDB)

        guard let saved = try? await existingShare(rootRecordID: recordID, in: privateDB),
              let url = saved.url
        else {
            throw ClubSyncError.transport("CloudKit did not return a share URL.")
        }
        zoneCache[club.id] = zoneID
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
        let query = CKQuery(
            recordType: RecordType.club,
            predicate: NSPredicate(format: "clubId == %@", id)
        )
        guard let record = try await records(matching: query, in: sharedDB).first else {
            return nil
        }
        zoneCache[id] = record.recordID.zoneID
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
            zone: zoneID, recordName: snapshot.memberId
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
        return try await records(matching: query, in: database(for: zoneID)).map {
            try decode(ClubMemberNotes.self, from: $0)
        }
    }

    public func deleteSnapshot(clubId: String, memberId: String) async throws {
        let zoneID = try await zoneID(forClubId: clubId)
        let (database, recordID) = databaseAndRecordID(zone: zoneID, recordName: memberId)
        try? await deleteRecord(recordID, in: database)
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
        let query = CKQuery(
            recordType: RecordType.club,
            predicate: NSPredicate(format: "clubId == %@", clubId)
        )
        guard let record = try await records(matching: query, in: sharedDB).first else {
            throw ClubSyncError.transport("Club not found in CloudKit: \(clubId)")
        }
        zoneCache[clubId] = record.recordID.zoneID
        return record.recordID.zoneID
    }

    private func database(for zone: CKRecordZone.ID) -> CKDatabase {
        zone.ownerName == CKCurrentUserDefaultName ? privateDB : sharedDB
    }

    private func databaseAndRecordID(
        zone: CKRecordZone.ID, recordName: String
    ) -> (CKDatabase, CKRecord.ID) {
        (database(for: zone), CKRecord.ID(recordName: recordName, zoneID: zone))
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
                        throwing: error
                            ?? ClubSyncError.transport(
                                "CloudKit returned no record: \(record.recordID.recordName)"
                            )
                    )
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

    private func modifyRecords(
        saving records: [CKRecord], in database: CKDatabase
    ) async throws -> [CKRecord] {
        do {
            let result = try await database.modifyRecords(
                saving: records, deleting: [], savePolicy: .changedKeys, atomically: true
            )
            return try result.saveResults.values.map { try $0.get() }
        } catch let error as CKError {
            throw ClubSyncError.transport(error.localizedDescription)
        }
    }

    private func records(
        matching query: CKQuery, in database: CKDatabase
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
              let bookTitle = record["bookTitle"] as? String,
              let rawURL = record["shareURL"] as? String,
              let url = URL(string: rawURL),
              let expiresAt = record["expiresAt"] as? Date
        else {
            throw ClubSyncError.transport("Malformed invite record: \(code)")
        }
        return ClubInvite(
            code: code, clubId: clubId, clubName: clubName,
            bookTitle: bookTitle, shareURL: url, expiresAt: expiresAt
        )
    }

    /// CKRecord hands `Data` values back as `NSData`; accept either.
    private func recordData(_ record: CKRecord) -> Data? {
        if let data = record["payload"] as? Data { return data }
        if let data = record["payload"] as? NSData { return data as Data }
        return nil
    }
}
