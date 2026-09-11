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
                errorMessage = String(describing: error)
                return
            }
        }
        guard let store else { return }
        await activate(store: store)
    }

    /// Wires the model to the app's core store. `engine` injects a transport
    /// for tests; `nil` picks CloudKit or the local-only engine.
    public func activate(store: CoreStore, engine: (any ClubSyncEngine)? = nil) async {
        self.store = store
        identity = (try? await store.clubIdentity()) ?? ClubIdentity(memberId: "local")
        spoilerProtection = (try? await store.clubSpoilerProtection()) ?? true
        let sync = if let engine {
            ClubSync(store: store, engine: engine)
        } else {
            await ClubSync.automatic(store: store)
        }
        self.sync = sync
        supportsSharing = sync.supportsSharing
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
            errorMessage = String(describing: error)
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
            errorMessage = String(describing: error)
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
            errorMessage = String(describing: error)
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
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Rebuilds the member's snapshot from the local notes and publishes it.
    @discardableResult
    public func publishOwnSnapshot() async -> Bool {
        guard let sync, let id = selectedClubID else { return false }
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
            errorMessage = String(describing: error)
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
            errorMessage = String(describing: error)
            return nil
        }
    }

    public func removeMember(id memberId: String) async {
        guard let sync, let id = selectedClubID else { return }
        do {
            _ = try await sync.removeMember(clubId: id, memberId: memberId)
            await refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func deleteSelectedClub() async {
        guard let store, let id = selectedClubID else { return }
        do {
            try await store.deleteClub(id: id)
            selectedClubID = nil
            selectedClub = nil
            notes = nil
            await refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setSpoilerProtection(_ enabled: Bool) async {
        guard let store else { return }
        do {
            try await store.setClubSpoilerProtection(enabled)
            spoilerProtection = enabled
            await loadNotes(spoilerEnabled: enabled)
        } catch {
            errorMessage = String(describing: error)
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
            errorMessage = String(describing: error)
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
}
