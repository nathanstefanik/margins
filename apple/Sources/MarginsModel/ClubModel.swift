import Foundation
import Observation
import MarginsCore

/// Model layer for private book clubs, shared by both frontends. Owns the
/// club list, selection, the merged club document, and the create/join
/// flows; mirrors `LibraryModel`'s UI-agnostic `@MainActor @Observable`
/// shape.
///
/// All persistence and transport go through `ClubSync` (local store plus
/// CloudKit, with a local-only fallback). Views own their presentation
/// details; this type owns the single source of truth.
@MainActor
@Observable
public final class ClubModel {
    public private(set) var clubs: [Club] = []
    public private(set) var selectedClub: Club?
    /// The selected club's merged document, spoiler gating applied.
    public private(set) var notes: ClubNotes?
    public private(set) var identity = ClubIdentity(memberId: "local")
    /// False on the local-only engine (unsigned build, no iCloud account).
    public private(set) var supportsSharing = false
    public private(set) var isBusy = false
    /// The persisted spoiler setting (default on).
    public private(set) var spoilerProtection = true

    /// Sheet presentation, owned here so menu commands and sidebar buttons
    /// open the same sheets. Views bind to these.
    public var createSheetPresented = false
    public var joinSheetPresented = false

    public var selectedClubID: String?
    /// The last non-fatal failure, surfaced as a transient banner.
    public var errorMessage: String?

    private let dataDir: String?
    private var store: CoreStore?
    private var sync: ClubSync?
    private var publishTasks: [String: Task<Void, Never>] = [:]

    /// - Parameter dataDir: explicit data directory for a self-activated
    ///   model, or `nil` when the app passes in the library's store.
    public init(dataDir: String? = nil) {
        self.dataDir = dataDir
    }

    /// Opens a core store from `dataDir` (tests, previews) and activates.
    public func activate() async {
        if store == nil {
            do {
                store = try CoreStore(dataDir: dataDir)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        guard let store else { return }
        await activate(store: store)
    }

    /// Wires the model to the app's core store. `engine` injects a transport
    /// for tests; `nil` picks CloudKit or the local-only engine.
    ///
    /// The member id comes from the transport, not the config: CloudKit
    /// rosters must use the user record name for participant removal to
    /// work. The config id is the fallback while a signed-in transport is
    /// temporarily unreachable.
    public func activate(store: CoreStore, engine: (any ClubSyncEngine)? = nil) async {
        self.store = store
        spoilerProtection = (try? await store.clubSpoilerProtection()) ?? true
        let sync = if let engine {
            ClubSync(store: store, engine: engine)
        } else {
            await ClubSync.automatic(store: store)
        }
        self.sync = sync
        supportsSharing = sync.supportsSharing

        let storedIdentity = try? await store.clubIdentity()
        identity = ClubIdentity(
            memberId: (try? await sync.currentMemberId())
                ?? storedIdentity?.memberId
                ?? "local",
            displayName: storedIdentity?.displayName
        )
        await refresh()
    }

    /// Reloads the club list, keeping a still-present selection.
    public func refresh() async {
        guard let store else { return }
        do {
            clubs = try await store.listClubs()
            if let selectedClubID, clubs.contains(where: { $0.id == selectedClubID }) {
                selectedClub = clubs.first { $0.id == selectedClubID }
                await loadNotes()
            } else {
                selectedClubID = nil
                selectedClub = nil
                notes = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Programmatically selects a club and loads its merged document.
    public func selectClub(id: String?) async {
        selectedClubID = id
        guard let id else {
            selectedClub = nil
            notes = nil
            return
        }
        selectedClub = clubs.first { $0.id == id }
        // A club missing from the local list was just deleted (or never
        // belonged here). Do not `syncClub`, which would fetch the CloudKit
        // record and write it back.
        guard selectedClub != nil else {
            notes = nil
            return
        }
        await loadNotes()
    }

    /// Pulls the shared club record and every member snapshot, then merges.
    /// `spoilerEnabled` overrides the setting for one load (the reveal
    /// control); `nil` reads the setting.
    public func loadNotes(spoilerEnabled: Bool? = nil) async {
        guard let sync, let id = selectedClubID else { return }
        do {
            notes = try await sync.syncClub(
                clubId: id, viewerId: identity.memberId, spoilerEnabled: spoilerEnabled
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Mutations

    @discardableResult
    public func createClub(
        bookId: String, name: String, displayName: String
    ) async -> Club? {
        guard let sync, let store else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.setClubDisplayName(displayName)
            identity = ClubIdentity(memberId: identity.memberId, displayName: displayName)
            let result = try await sync.createClub(
                bookId: bookId, name: name,
                memberId: identity.memberId, displayName: displayName
            )
            await refresh()
            await selectClub(id: result.club.id)
            return result.club
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func joinClub(code: String, displayName: String) async -> Club? {
        guard let sync, let store else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.setClubDisplayName(displayName)
            identity = ClubIdentity(memberId: identity.memberId, displayName: displayName)
            let club = try await sync.joinClub(
                code: code, memberId: identity.memberId, displayName: displayName
            )
            await refresh()
            await selectClub(id: club.id)
            return club
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Rebuilds the member's snapshot from the local notes and publishes it.
    @discardableResult
    public func publishOwnSnapshot() async -> Bool {
        guard let sync, let id = selectedClubID else { return false }
        if let bookId = selectedClub?.bookId {
            publishTasks[bookId]?.cancel()
            publishTasks[bookId] = nil
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await sync.publishOwnSnapshot(
                clubId: id, memberId: identity.memberId,
                displayName: identity.displayName ?? "You"
            )
            await loadNotes()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func schedulePublish(bookId: String) {
        publishTasks[bookId]?.cancel()
        publishTasks[bookId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.publishNotes(bookId: bookId)
        }
    }

    private func publishNotes(bookId: String) async {
        defer { publishTasks[bookId] = nil }
        guard let sync else { return }
        let matches = clubs.filter { $0.bookId == bookId }
        guard !matches.isEmpty else { return }
        let name = identity.displayName ?? "You"
        for club in matches {
            do {
                try await sync.publishOwnSnapshot(
                    clubId: club.id, memberId: identity.memberId, displayName: name
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func renameSelectedClub(_ name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Name can't be empty."
            return false
        }
        guard let sync, let id = selectedClubID else { return false }
        guard isAdmin(of: selectedClub) else {
            errorMessage = "Only the club admin can do that."
            return false
        }
        do {
            _ = try await sync.renameClub(clubId: id, name: name)
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func setDisplayName(_ name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Name can't be empty."
            return false
        }
        guard let sync else { return false }
        do {
            try await sync.setDisplayName(name, memberId: identity.memberId)
            identity = ClubIdentity(memberId: identity.memberId, displayName: name)
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func promoteMember(id memberId: String) async -> Bool {
        guard let sync, let id = selectedClubID else { return false }
        guard isAdmin(of: selectedClub) else {
            errorMessage = "Only the club admin can do that."
            return false
        }
        guard memberId != identity.memberId, selectedClub?.member(id: memberId) != nil else {
            return false
        }
        do {
            _ = try await sync.transferAdmin(clubId: id, to: memberId)
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func rotateInviteCode() async -> String? {
        guard let sync, let id = selectedClubID else { return nil }
        do {
            let code = try await sync.rotateInviteCode(clubId: id)
            await refresh()
            return code
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func removeMember(id memberId: String) async {
        guard let sync, let id = selectedClubID else { return }
        do {
            _ = try await sync.removeMember(clubId: id, memberId: memberId)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func deleteSelectedClub() async -> Bool {
        guard let sync, let id = selectedClubID else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await sync.deleteClub(id: id)
            selectedClubID = nil
            selectedClub = nil
            notes = nil
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Leaves as a member: roster and snapshot go, local copy goes, the
    /// owner's club remains. Admins delete instead.
    @discardableResult
    public func leaveSelectedClub() async -> Bool {
        guard let sync, let id = selectedClubID else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await sync.leaveClub(id: id, memberId: identity.memberId)
            selectedClubID = nil
            selectedClub = nil
            notes = nil
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func setSpoilerProtection(_ enabled: Bool) async {
        guard let store else { return }
        do {
            try await store.setClubSpoilerProtection(enabled)
            spoilerProtection = enabled
            await loadNotes(spoilerEnabled: enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rendered club markdown plus the suggested file name, for the save
    /// panel. `options` of `.meetingBrief` drops long-form notes.
    public func exportMarkdown(
        options: ClubExportOptions = .default
    ) async -> (markdown: String, filename: String)? {
        guard let sync, let id = selectedClubID, let notes else { return nil }
        do {
            let markdown = try await sync.store.renderClubNotesMarkdown(
                clubId: id, viewerId: identity.memberId,
                spoilerEnabled: spoilerProtection, options: options
            )
            return (markdown, notes.suggestedFilename)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Identity helpers

    public func isCurrentMember(_ member: ClubMember) -> Bool {
        member.id == identity.memberId
    }

    public func isAdmin(of club: Club?) -> Bool {
        club?.isAdmin(identity.memberId) ?? false
    }

    public func isOwner(of club: Club?) -> Bool {
        club?.isOwner(identity.memberId) ?? false
    }
}
