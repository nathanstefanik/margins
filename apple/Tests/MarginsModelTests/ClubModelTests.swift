import Foundation
import MarginsCore
@testable import MarginsModel
import Testing

/// The UI-facing club model, driven through the local-only engine so the
/// whole flow runs without iCloud.
@Suite("Club model")
@MainActor
struct ClubModelTests {
    @Test("create, sync, export, and delete through the model")
    func lifecycle() async throws {
        let store = try CoreStore(dataDir: try makeTempDataDir())
        let fixture = try #require(try fixtureEpubs().first)
        let book = try await store.importEpub(atPath: fixture)
        let identity = try await store.clubIdentity()
        let model = ClubModel()
        await model.activate(
            store: store,
            engine: LocalClubSyncEngine(store: store, memberId: identity.memberId)
        )
        #expect(model.clubs.isEmpty)
        #expect(!model.supportsSharing)

        let created = await model.createClub(
            bookId: book.id, name: "Solo", displayName: "Alice"
        )
        let club = try #require(created)
        #expect(model.clubs.map(\.id) == [club.id])
        #expect(model.selectedClubID == club.id)
        #expect(model.identity.displayName == "Alice")
        #expect(model.isAdmin(of: club))

        let chapter = try #require(book.chapters.first)
        _ = try await store.saveChapterNote(
            bookId: book.id, chapter: ChapterRef(key: chapter.key, epubCfi: nil),
            body: "A thought.", kind: nil
        )
        #expect(await model.publishOwnSnapshot())
        #expect(model.notes?.chapters.first?.contributions.first?.body == "A thought.")

        await model.setSpoilerProtection(false)
        #expect(!model.spoilerProtection)

        let export = await model.exportMarkdown()
        #expect(export?.markdown.contains("A thought.") == true)
        #expect(export?.filename.hasSuffix("club notes.md") == true)

        await model.deleteSelectedClub()
        #expect(model.clubs.isEmpty)
        #expect(model.selectedClub == nil)
        #expect(model.notes == nil)
    }
}
